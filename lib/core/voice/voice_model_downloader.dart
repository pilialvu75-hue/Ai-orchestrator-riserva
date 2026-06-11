import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';

class VoiceAssetException implements Exception {
  const VoiceAssetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VoiceModelDownloader with RuntimeEventEmitter {
  VoiceModelDownloader({
    Dio? dio,
    RuntimeModelPathResolver? pathResolver,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 1),
                sendTimeout: const Duration(seconds: 30),
                followRedirects: true,
                maxRedirects: 10,
              ),
            ),
        _pathResolver = pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';

  // Soglia minima di validazione: 70% della dimensione attesa.
  // Abbassata rispetto all'85% per gestire variazioni nei file piccoli
  // (tokens.txt, decoder.onnx) dove le dimensioni stimate possono
  // differire significativamente dalla dimensione reale sul server.
  static const double _minValidationRatio = 0.70;

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_BEGIN] checking storage requirements for voice assets',
    );
    if (!Platform.isAndroid) {
      logEvent(
        _tag,
        '[PERMISSION_REQUEST_RESULT] no runtime storage permission required on this platform',
      );
      return true;
    }

    logEvent(
      _tag,
      '[PERMISSION_REQUEST_RESULT] no runtime storage permission required; '
      'voice assets use app-private storage to avoid Android 11+ (API 30+) '
      'shared-storage restrictions and Android 13+ (API 33+) media permission limits',
    );
    return true;
  }

  /// Scarica tutti i modelli vocali necessari.
  ///
  /// STT: 4 file ONNX individuali da Hugging Face
  /// (encoder, decoder, joiner, tokens).
  ///
  /// TTS: archivio tar.bz2 da GitHub Releases di sherpa-onnx
  /// contenente it_IT-paola-medium.onnx, tokens.txt e espeak-ng-data/.
  /// L'archivio viene estratto nella directory privata dell'app.
  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');

    // ── Fase 1: file STT individuali (4 file) ──────────────────────────────
    final sttSpecs = _sttModelSpecs;
    const sttTotalBytes = (170 + 18) * 1024 * 1024 + 400 * 1024 + 7 * 1024;
    final ttsTotalBytes = AppConstants.ttsPaolaTarExpectedBytes;
    const grandTotal = sttTotalBytes + ttsTotalBytes;

    var completedBytes = 0;
    onProgress(0.0);

    for (final spec in sttSpecs) {
      final destinationFile = File('${targetDir.path}/${spec.fileName}');
      logEvent(_tag, '[URL_RESOLVE] file=${spec.fileName} url=${spec.url}');

      if (await _validateExistingFile(spec, destinationFile)) {
        logEvent(_tag, '[DOWNLOAD_SKIP] file=${spec.fileName}');
        completedBytes += spec.expectedBytes;
        onProgress(
            (completedBytes / grandTotal).clamp(0.0, 1.0).toDouble());
        continue;
      }

      final tempFile = File('${destinationFile.path}.part');
      if (await tempFile.exists()) await tempFile.delete();
      if (await destinationFile.exists()) await destinationFile.delete();

      logEvent(_tag, '[DOWNLOAD_FILE_BEGIN] file=${spec.fileName}');

      try {
        await _dio.download(
          spec.url,
          tempFile.path,
          deleteOnError: true,
          options: Options(
            followRedirects: true,
            maxRedirects: 10,
          ),
          onReceiveProgress: (received, total) {
            final denominator = total > 0 ? total : spec.expectedBytes;
            final fileProgress =
                (received / denominator).clamp(0.0, 1.0);
            final aggregate =
                (completedBytes + fileProgress * spec.expectedBytes) /
                    grandTotal;
            onProgress(aggregate.clamp(0.0, 1.0).toDouble());
          },
        );

        await _validateDownloadedFile(spec, tempFile);
        await tempFile.rename(destinationFile.path);
        await _validateDownloadedFile(spec, destinationFile);

        logEvent(
          _tag,
          '[DOWNLOAD_FILE_COMPLETE] file=${spec.fileName} path=${destinationFile.path}',
        );
      } on DioException catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        final statusCode = error.response?.statusCode;
        final message = statusCode == null
            ? 'Download STT fallito: ${spec.fileName}. ${error.message ?? "Errore di rete"}'
            : 'Download STT fallito: ${spec.fileName} (HTTP $statusCode).';
        logEvent(
            _tag, '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=$message');
        throw VoiceAssetException(message);
      } on VoiceAssetException {
        await _cleanupTempFiles(tempFile, destinationFile);
        rethrow;
      } catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        throw VoiceAssetException(
            'Download STT fallito: ${spec.fileName}. $error');
      }

      completedBytes += spec.expectedBytes;
      onProgress(
          (completedBytes / grandTotal).clamp(0.0, 1.0).toDouble());
    }

    // ── Fase 2: archivio TTS tar.bz2 (Paola Piper) ────────────────────────
    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (ttsProgress) {
        final aggregate =
            (completedBytes + ttsProgress * ttsTotalBytes) / grandTotal;
        onProgress(aggregate.clamp(0.0, 1.0).toDouble());
      },
    );

    await validateDownloadedAssets();
    logEvent(
        _tag, '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}');
    onProgress(1.0);
  }

  /// Scarica il tar.bz2 del modello TTS Piper Paola ed estrae i file.
  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    final ttsModelFile =
        File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final ttsTokensFile =
        File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));

    final alreadyExtracted = await ttsModelFile.exists() &&
        await ttsTokensFile.exists() &&
        await espeakDir.exists() &&
        (await ttsModelFile.length()) > (50 * 1024 * 1024);

    if (alreadyExtracted) {
      logEvent(
        _tag,
        '[TTS_TAR_SKIP] TTS assets already extracted to ${targetDir.path}',
      );
      onProgress(1.0);
      return;
    }

    final tarPath =
        p.join(targetDir.path, 'vits-piper-it_IT-paola-medium.tar.bz2');
    final tarFile = File(tarPath);

    if (!await tarFile.exists() ||
        (await tarFile.length()) <
            (AppConstants.ttsPaolaTarExpectedBytes * 0.70).toInt()) {
      if (await tarFile.exists()) await tarFile.delete();

      logEvent(
        _tag,
        '[TTS_TAR_DOWNLOAD_BEGIN] url=${AppConstants.ttsPaolaTarUrl}',
      );

      try {
        await _dio.download(
          AppConstants.ttsPaolaTarUrl,
          tarPath,
          deleteOnError: true,
          options: Options(
            followRedirects: true,
            maxRedirects: 10,
          ),
          onReceiveProgress: (received, total) {
            final denominator =
                total > 0 ? total : AppConstants.ttsPaolaTarExpectedBytes;
            onProgress((received / denominator).clamp(0.0, 0.8).toDouble());
          },
        );
        logEvent(_tag, '[TTS_TAR_DOWNLOAD_COMPLETE] path=$tarPath');
      } on DioException catch (error) {
        if (await tarFile.exists()) await tarFile.delete();
        final statusCode = error.response?.statusCode;
        final message = statusCode == null
            ? 'Download TTS tar fallito. ${error.message ?? "Errore di rete"}'
            : 'Download TTS tar fallito (HTTP $statusCode).';
        logEvent(_tag, '[TTS_TAR_DOWNLOAD_FAIL] error=$message');
        throw VoiceAssetException(message);
      } catch (error) {
        if (await tarFile.exists()) await tarFile.delete();
        throw VoiceAssetException('Download TTS tar fallito. $error');
      }
    } else {
      logEvent(_tag, '[TTS_TAR_SKIP_DOWNLOAD] tar already present');
      onProgress(0.8);
    }

    // Estrai il tar.bz2.
    logEvent(
        _tag, '[TTS_TAR_EXTRACT_BEGIN] tar=$tarPath dest=${targetDir.path}');
    onProgress(0.85);

    try {
      final bytes = await tarFile.readAsBytes();
      final bz2Decoder = BZip2Decoder();
      final tarBytes = bz2Decoder.decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);

      for (final file in archive) {
        var outPath = file.name;
        const prefix = 'vits-piper-it_IT-paola-medium/';
        if (outPath.startsWith(prefix)) {
          outPath = outPath.substring(prefix.length);
        }
        if (outPath.isEmpty) continue;

        // Rinomina tokens.txt del TTS per non confonderlo con quello STT.
        if (outPath == 'tokens.txt') {
          outPath = AppConstants.ttsTokensFile;
        }

        final destPath = p.join(targetDir.path, outPath);

        if (file.isFile) {
          final destFile = File(destPath);
          await destFile.parent.create(recursive: true);
          await destFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(destPath).create(recursive: true);
        }
      }

      logEvent(_tag, '[TTS_TAR_EXTRACT_COMPLETE]');
      onProgress(0.95);
    } catch (error) {
      throw VoiceAssetException('Estrazione TTS tar fallita: $error');
    } finally {
      if (await tarFile.exists()) {
        await tarFile.delete();
        logEvent(_tag, '[TTS_TAR_CLEANUP] deleted $tarPath');
      }
    }

    onProgress(1.0);
  }

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN] checking required voice files');
    final targetDir = await _pathResolver.privateModelsDirectory();
    final missingOrInvalid = <String>[];

    for (final spec in _sttModelSpecs) {
      final file = File(p.join(targetDir.path, spec.fileName));
      if (!await _validateExistingFile(spec, file)) {
        logEvent(_tag, '[ASSET_MISSING] stt file=${spec.fileName}');
        missingOrInvalid.add(spec.fileName);
      }
    }

    final ttsModelFile =
        File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final ttsTokensFile =
        File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));

    if (!await ttsModelFile.exists() ||
        (await ttsModelFile.length()) < (50 * 1024 * 1024)) {
      logEvent(
          _tag, '[ASSET_MISSING] tts model=${AppConstants.ttsModelFile}');
      missingOrInvalid.add(AppConstants.ttsModelFile);
    }
    if (!await ttsTokensFile.exists() ||
        (await ttsTokensFile.length()) == 0) {
      logEvent(
          _tag, '[ASSET_MISSING] tts tokens=${AppConstants.ttsTokensFile}');
      missingOrInvalid.add(AppConstants.ttsTokensFile);
    }
    if (!await espeakDir.exists()) {
      logEvent(
          _tag, '[ASSET_MISSING] espeak-ng-data dir=${espeakDir.path}');
      missingOrInvalid.add(AppConstants.ttsEspeakDataDir);
    }

    if (missingOrInvalid.isNotEmpty) {
      final message =
          'Risorse vocali mancanti o non valide: ${missingOrInvalid.join(", ")}. '
          'Riprova il download dei modelli vocali.';
      logEvent(_tag, '[ASSET_VALIDATION_FAIL] $message');
      throw VoiceAssetException(message);
    }

    logEvent(
      _tag,
      '[ASSET_VALIDATION_COMPLETE] all voice assets available dir=${targetDir.path}',
    );
  }

  Future<Directory> _ensureTargetDirectory() async {
    final targetDir = await _pathResolver.privateModelsDirectory();
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }

  Future<bool> _validateExistingFile(
    _VoiceModelDownloadSpec spec,
    File file,
  ) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      // Soglia 70% per gestire variazioni nei file piccoli.
      final minBytes = (spec.expectedBytes * _minValidationRatio).toInt();
      return length >= minBytes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _validateDownloadedFile(
    _VoiceModelDownloadSpec spec,
    File file,
  ) async {
    if (!await file.exists()) {
      throw VoiceAssetException(
        'File vocale non trovato dopo il download: ${spec.fileName}.',
      );
    }
    final length = await file.length();
    if (length <= 0) {
      throw VoiceAssetException(
        'File vocale vuoto dopo il download: ${spec.fileName}.',
      );
    }
    final minBytes = (spec.expectedBytes * _minValidationRatio).toInt();
    if (length < minBytes) {
      throw VoiceAssetException(
        'File vocale incompleto o corrotto: ${spec.fileName} '
        '($length byte rilevati, attesi almeno $minBytes).',
      );
    }
  }

  Future<void> _cleanupTempFiles(File tempFile, File destinationFile) async {
    if (await tempFile.exists()) {
      logEvent(
          _tag, '[CLEANUP_TEMP] deleting temp file: ${tempFile.path}');
      await tempFile.delete();
    }
    if (await destinationFile.exists()) {
      logEvent(
          _tag,
          '[CLEANUP_DEST] deleting partial destination: ${destinationFile.path}');
      await destinationFile.delete();
    }
  }

  List<_VoiceModelDownloadSpec> get _sttModelSpecs =>
      const <_VoiceModelDownloadSpec>[
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttEncoderFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/encoder-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 170 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttDecoderFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 400 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttJoinerFile,
          url:
              '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
          expectedBytes: 18 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.sttTokensFile,
          url: '${AppConstants.sttZipformerBaseUrl}/tokens.txt',
          expectedBytes: 7 * 1024,
        ),
      ];
}

class _VoiceModelDownloadSpec {
  const _VoiceModelDownloadSpec({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
  });

  final String fileName;
  final String url;
  final int expectedBytes;
}
