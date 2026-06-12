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
                receiveTimeout: const Duration(hours: 2),
                sendTimeout: const Duration(seconds: 30),
                followRedirects: true,
                maxRedirects: 10,
              ),
            ),
        _pathResolver = pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';

  // Soglia minima di validazione: 70% della dimensione attesa.
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
  /// STT: archivio tar.bz2 da GitHub Releases di sherpa-onnx
  /// contenente encoder.onnx, decoder.onnx, joiner.onnx, tokens.txt.
  ///
  /// TTS: archivio tar.bz2 da GitHub Releases di sherpa-onnx
  /// contenente it_IT-paola-medium.onnx, tokens.txt e espeak-ng-data/.
  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');

    onProgress(0.0);

    // ── Fase 1: archivio STT tar.bz2 ──────────────────────────────────────
    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (sttProgress) {
        onProgress((sttProgress * 0.5).clamp(0.0, 0.5));
      },
    );

    // ── Fase 2: archivio TTS tar.bz2 (Paola Piper) ────────────────────────
    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (ttsProgress) {
        onProgress((0.5 + ttsProgress * 0.5).clamp(0.0, 1.0));
      },
    );

    await validateDownloadedAssets();
    logEvent(
        _tag, '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}');
    onProgress(1.0);
  }

  /// Scarica il tar.bz2 del modello STT Zipformer EN ed estrae i file.
  ///
  /// Struttura attesa nell'archivio:
  ///   sherpa-onnx-streaming-zipformer-en-2023-06-26/
  ///     encoder-epoch-99-avg-1-chunk-16-left-128.onnx  → encoder.onnx
  ///     decoder-epoch-99-avg-1-chunk-16-left-128.onnx  → decoder.onnx
  ///     joiner-epoch-99-avg-1-chunk-16-left-128.onnx   → joiner.onnx
  ///     tokens.txt                                      → tokens.txt
  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    final encoderFile =
        File(p.join(targetDir.path, AppConstants.sttEncoderFile));
    final decoderFile =
        File(p.join(targetDir.path, AppConstants.sttDecoderFile));
    final joinerFile =
        File(p.join(targetDir.path, AppConstants.sttJoinerFile));
    final tokensFile =
        File(p.join(targetDir.path, AppConstants.sttTokensFile));

    final alreadyExtracted = await encoderFile.exists() &&
        await decoderFile.exists() &&
        await joinerFile.exists() &&
        await tokensFile.exists() &&
        (await encoderFile.length()) > (100 * 1024 * 1024);

    if (alreadyExtracted) {
      logEvent(_tag, '[STT_TAR_SKIP] STT assets already extracted');
      onProgress(1.0);
      return;
    }

    final tarPath = p.join(
        targetDir.path, 'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2');
    final tarFile = File(tarPath);

    if (!await tarFile.exists() ||
        (await tarFile.length()) <
            (AppConstants.sttZipformerTarExpectedBytes * 0.70).toInt()) {
      if (await tarFile.exists()) await tarFile.delete();

      logEvent(
        _tag,
        '[STT_TAR_DOWNLOAD_BEGIN] url=${AppConstants.sttZipformerTarUrl}',
      );

      try {
        await _dio.download(
          AppConstants.sttZipformerTarUrl,
          tarPath,
          deleteOnError: true,
          options: Options(
            followRedirects: true,
            maxRedirects: 10,
          ),
          onReceiveProgress: (received, total) {
            final denominator =
                total > 0 ? total : AppConstants.sttZipformerTarExpectedBytes;
            onProgress((received / denominator).clamp(0.0, 0.8).toDouble());
          },
        );
        logEvent(_tag, '[STT_TAR_DOWNLOAD_COMPLETE] path=$tarPath');
      } on DioException catch (error) {
        if (await tarFile.exists()) await tarFile.delete();
        final statusCode = error.response?.statusCode;
        final message = statusCode == null
            ? 'Download STT tar fallito. ${error.message ?? "Errore di rete"}'
            : 'Download STT tar fallito (HTTP $statusCode).';
        logEvent(_tag, '[STT_TAR_DOWNLOAD_FAIL] error=$message');
        throw VoiceAssetException(message);
      } catch (error) {
        if (await tarFile.exists()) await tarFile.delete();
        throw VoiceAssetException('Download STT tar fallito. $error');
      }
    } else {
      logEvent(_tag, '[STT_TAR_SKIP_DOWNLOAD] tar already present');
      onProgress(0.8);
    }

    logEvent(
        _tag, '[STT_TAR_EXTRACT_BEGIN] tar=$tarPath dest=${targetDir.path}');
    onProgress(0.85);

    try {
      final bytes = await tarFile.readAsBytes();
      final bz2Decoder = BZip2Decoder();
      final tarBytes = bz2Decoder.decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);

      const prefix = 'sherpa-onnx-streaming-zipformer-en-2023-06-26/';

      for (final file in archive) {
        var outPath = file.name;
        if (outPath.startsWith(prefix)) {
          outPath = outPath.substring(prefix.length);
        }
        if (outPath.isEmpty) continue;

        // Rinomina i file con i nomi attesi dall'app.
        if (outPath.contains('encoder')) {
          outPath = AppConstants.sttEncoderFile;
        } else if (outPath.contains('decoder')) {
          outPath = AppConstants.sttDecoderFile;
        } else if (outPath.contains('joiner')) {
          outPath = AppConstants.sttJoinerFile;
        } else if (outPath == 'tokens.txt') {
          outPath = AppConstants.sttTokensFile;
        } else {
          // Salta file non necessari (test_wavs, README, script shell).
          continue;
        }

        if (file.isFile) {
          final destFile = File(p.join(targetDir.path, outPath));
          await destFile.parent.create(recursive: true);
          await destFile.writeAsBytes(file.content as List<int>);
          logEvent(_tag, '[STT_TAR_FILE_EXTRACTED] $outPath');
        }
      }

      logEvent(_tag, '[STT_TAR_EXTRACT_COMPLETE]');
      onProgress(0.95);
    } catch (error) {
      throw VoiceAssetException('Estrazione STT tar fallita: $error');
    } finally {
      if (await tarFile.exists()) {
        await tarFile.delete();
        logEvent(_tag, '[STT_TAR_CLEANUP] deleted $tarPath');
      }
    }

    onProgress(1.0);
  }

  /// Scarica il tar.bz2 del modello TTS Piper Paola ed estrae i file.
  ///
  /// Struttura attesa nell'archivio:
  ///   vits-piper-it_IT-paola-medium/
  ///     it_IT-paola-medium.onnx
  ///     tokens.txt
  ///     espeak-ng-data/
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
      logEvent(_tag, '[TTS_TAR_SKIP] TTS assets already extracted');
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

    logEvent(
        _tag, '[TTS_TAR_EXTRACT_BEGIN] tar=$tarPath dest=${targetDir.path}');
    onProgress(0.85);

    try {
      final bytes = await tarFile.readAsBytes();
      final bz2Decoder = BZip2Decoder();
      final tarBytes = bz2Decoder.decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);

      const prefix = 'vits-piper-it_IT-paola-medium/';

      for (final file in archive) {
        var outPath = file.name;
        if (outPath.startsWith(prefix)) {
          outPath = outPath.substring(prefix.length);
        }
        if (outPath.isEmpty) continue;

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

    // Valida file STT.
    final sttFiles = <String, int>{
      AppConstants.sttEncoderFile: 100 * 1024 * 1024,
      AppConstants.sttDecoderFile: 200 * 1024,
      AppConstants.sttJoinerFile: 10 * 1024 * 1024,
      AppConstants.sttTokensFile: 1024,
    };

    for (final entry in sttFiles.entries) {
      final file = File(p.join(targetDir.path, entry.key));
      final minBytes = entry.value;
      if (!await file.exists() || (await file.length()) < minBytes) {
        logEvent(_tag, '[ASSET_MISSING] stt file=${entry.key}');
        missingOrInvalid.add(entry.key);
      }
    }

    // Valida file TTS.
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
}
