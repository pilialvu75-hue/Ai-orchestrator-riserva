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

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_BEGIN] checking storage requirements',
    );
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_RESULT] using app-private storage',
    );
    return true;
  }

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');

    onProgress(0.0);

    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (sttProgress) {
        onProgress((sttProgress * 0.5).clamp(0.0, 0.5));
      },
    );

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

  /// Verifica che tutti i file STT siano presenti e validi.
  /// Solo se tutti e 4 i file sono ok, salta il download.
  Future<bool> _sttAssetsComplete(Directory targetDir) async {
    final encoderFile =
        File(p.join(targetDir.path, AppConstants.sttEncoderFile));
    final decoderFile =
        File(p.join(targetDir.path, AppConstants.sttDecoderFile));
    final joinerFile =
        File(p.join(targetDir.path, AppConstants.sttJoinerFile));
    final tokensFile =
        File(p.join(targetDir.path, AppConstants.sttTokensFile));

    if (!await encoderFile.exists()) return false;
    if (!await decoderFile.exists()) return false;
    if (!await joinerFile.exists()) return false;
    if (!await tokensFile.exists()) return false;

    // Controlla dimensioni minime reali.
    if ((await encoderFile.length()) < (100 * 1024 * 1024)) return false;
    if ((await decoderFile.length()) < (200 * 1024)) return false;
    if ((await joinerFile.length()) < (10 * 1024 * 1024)) return false;
    if ((await tokensFile.length()) < 1024) return false;

    return true;
  }

  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    // Controlla se tutti i file STT sono già presenti e validi.
    if (await _sttAssetsComplete(targetDir)) {
      logEvent(_tag, '[STT_TAR_SKIP] all STT assets already valid');
      onProgress(1.0);
      return;
    }

    // Pulisce eventuali file parziali prima di ricominciare.
    await _cleanupSttFiles(targetDir);

    final tarPath = p.join(
      targetDir.path,
      'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2',
    );
    final tarFile = File(tarPath);

    // Scarica il tar.bz2.
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

    // Estrai il tar.bz2.
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

        // Rinomina con i nomi attesi dall'app.
        if (outPath.contains('encoder')) {
          outPath = AppConstants.sttEncoderFile;
        } else if (outPath.contains('decoder')) {
          outPath = AppConstants.sttDecoderFile;
        } else if (outPath.contains('joiner')) {
          outPath = AppConstants.sttJoinerFile;
        } else if (outPath == 'tokens.txt') {
          outPath = AppConstants.sttTokensFile;
        } else {
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

  Future<void> _cleanupSttFiles(Directory targetDir) async {
    final files = [
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ];
    for (final fileName in files) {
      final file = File(p.join(targetDir.path, fileName));
      if (await file.exists()) {
        await file.delete();
        logEvent(_tag, '[STT_CLEANUP] deleted $fileName');
      }
      final partFile = File('${file.path}.part');
      if (await partFile.exists()) {
        await partFile.delete();
        logEvent(_tag, '[STT_CLEANUP] deleted $fileName.part');
      }
    }
  }

  Future<bool> _ttsAssetsComplete(Directory targetDir) async {
    final ttsModelFile =
        File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final ttsTokensFile =
        File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));

    if (!await ttsModelFile.exists()) return false;
    if (!await ttsTokensFile.exists()) return false;
    if (!await espeakDir.exists()) return false;
    if ((await ttsModelFile.length()) < (50 * 1024 * 1024)) return false;

    return true;
  }

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _ttsAssetsComplete(targetDir)) {
      logEvent(_tag, '[TTS_TAR_SKIP] all TTS assets already valid');
      onProgress(1.0);
      return;
    }

    await _cleanupTtsFiles(targetDir);

    final tarPath =
        p.join(targetDir.path, 'vits-piper-it_IT-paola-medium.tar.bz2');
    final tarFile = File(tarPath);

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

  Future<void> _cleanupTtsFiles(Directory targetDir) async {
    final files = [
      AppConstants.ttsModelFile,
      AppConstants.ttsTokensFile,
    ];
    for (final fileName in files) {
      final file = File(p.join(targetDir.path, fileName));
      if (await file.exists()) {
        await file.delete();
        logEvent(_tag, '[TTS_CLEANUP] deleted $fileName');
      }
    }
    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));
    if (await espeakDir.exists()) {
      await espeakDir.delete(recursive: true);
      logEvent(_tag, '[TTS_CLEANUP] deleted espeak-ng-data');
    }
  }

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN] checking required voice files');
    final targetDir = await _pathResolver.privateModelsDirectory();
    final missingOrInvalid = <String>[];

    final sttFiles = <String, int>{
      AppConstants.sttEncoderFile: 100 * 1024 * 1024,
      AppConstants.sttDecoderFile: 200 * 1024,
      AppConstants.sttJoinerFile: 10 * 1024 * 1024,
      AppConstants.sttTokensFile: 1024,
    };

    for (final entry in sttFiles.entries) {
      final file = File(p.join(targetDir.path, entry.key));
      if (!await file.exists() || (await file.length()) < entry.value) {
        logEvent(_tag, '[ASSET_MISSING] stt file=${entry.key}');
        missingOrInvalid.add(entry.key);
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
      missingOrInvalid.add(AppConstants.ttsModelFile);
    }
    if (!await ttsTokensFile.exists() ||
        (await ttsTokensFile.length()) == 0) {
      missingOrInvalid.add(AppConstants.ttsTokensFile);
    }
    if (!await espeakDir.exists()) {
      missingOrInvalid.add(AppConstants.ttsEspeakDataDir);
    }

    if (missingOrInvalid.isNotEmpty) {
      final message =
          'Risorse vocali mancanti o non valide: ${missingOrInvalid.join(", ")}. '
          'Riprova il download dei modelli vocali.';
      logEvent(_tag, '[ASSET_VALIDATION_FAIL] $message');
      throw VoiceAssetException(message);
    }

    logEvent(_tag, '[ASSET_VALIDATION_COMPLETE] all voice assets ready');
  }

  Future<Directory> _ensureTargetDirectory() async {
    final targetDir = await _pathResolver.privateModelsDirectory();
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }
}
