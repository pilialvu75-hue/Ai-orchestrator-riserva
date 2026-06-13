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
                followRedirects: true,
                maxRedirects: 10,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 2),
                sendTimeout: const Duration(seconds: 30),
              ),
            ),
        _pathResolver = pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';
  static const String _sttTarFileName =
      'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2';
  static const String _ttsTarFileName = 'vits-piper-it_IT-paola-medium.tar.bz2';
  static String get _sttArchivePrefix =>
      _sttTarFileName.replaceFirst('.tar.bz2', '/');
  static String get _ttsArchivePrefix =>
      _ttsTarFileName.replaceFirst('.tar.bz2', '/');

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(_tag, '[PERMISSION_REQUEST_BEGIN]');
    logEvent(_tag, '[PERMISSION_REQUEST_RESULT] using app-private storage');
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
      onProgress: (value) => onProgress((value * 0.5).clamp(0.0, 0.5)),
    );

    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (value) => onProgress((0.5 + value * 0.5).clamp(0.0, 1.0)),
    );

    await validateDownloadedAssets();
    logEvent(_tag, '[DOWNLOAD_COMPLETE] voice assets ready');
    onProgress(1.0);
  }

  Future<bool> _sttAssetsComplete(Directory targetDir) async {
    return (await _sttInvalidAssets(targetDir)).isEmpty;
  }

  Future<List<String>> _sttInvalidAssets(Directory targetDir) async {
    final invalid = <String>[];
    final assets = <MapEntry<String, int>>[
      MapEntry(AppConstants.sttEncoderFile, 100 * 1024 * 1024),
      MapEntry(AppConstants.sttDecoderFile, 200 * 1024),
      MapEntry(AppConstants.sttJoinerFile, 10 * 1024 * 1024),
      MapEntry(AppConstants.sttTokensFile, 1024),
    ];
    for (final asset in assets) {
      final file = File(p.join(targetDir.path, asset.key));
      if (!await file.exists() || (await file.length()) < asset.value) {
        invalid.add(asset.key);
      }
    }
    return invalid;
  }

  Future<bool> _ttsAssetsComplete(Directory targetDir) async {
    return (await _ttsInvalidAssets(targetDir)).isEmpty;
  }

  Future<List<String>> _ttsInvalidAssets(Directory targetDir) async {
    final invalid = <String>[];
    final modelFile = File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final tokensFile = File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));

    if (!await modelFile.exists() ||
        (await modelFile.length()) <= 50 * 1024 * 1024) {
      invalid.add(AppConstants.ttsModelFile);
    }
    if (!await tokensFile.exists() || (await tokensFile.length()) == 0) {
      invalid.add(AppConstants.ttsTokensFile);
    }
    if (!await espeakDir.exists()) {
      invalid.add(AppConstants.ttsEspeakDataDir);
    }
    return invalid;
  }

  Future<void> _cleanupSttFiles(Directory targetDir) async {
    for (final name in <String>[
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ]) {
      final file = File(p.join(targetDir.path, name));
      if (await file.exists()) {
        await file.delete();
      }
      final partFile = File('${file.path}.part');
      if (await partFile.exists()) {
        await partFile.delete();
      }
    }
  }

  Future<void> _cleanupTtsFiles(Directory targetDir) async {
    for (final name in <String>[
      AppConstants.ttsModelFile,
      AppConstants.ttsTokensFile,
    ]) {
      final file = File(p.join(targetDir.path, name));
      if (await file.exists()) {
        await file.delete();
      }
    }

    final espeakDir =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));
    if (await espeakDir.exists()) {
      await espeakDir.delete(recursive: true);
    }
  }

  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _sttAssetsComplete(targetDir)) {
      logEvent(_tag, '[STT_TAR_SKIP] all STT assets valid');
      onProgress(1.0);
      return;
    }

    logEvent(_tag, '[STT_TAR_CLEANUP_SCHEDULED]');
    await _cleanupSttFiles(targetDir);

    final tarPath = p.join(targetDir.path, _sttTarFileName);
    await _downloadFile(
      url: AppConstants.sttZipformerTarUrl,
      destPath: tarPath,
      expectedBytes: AppConstants.sttZipformerTarExpectedBytes,
      tag: 'STT_TAR',
      onProgress: (value) => onProgress((value * 0.8).clamp(0.0, 0.8)),
    );

    logEvent(_tag, '[STT_TAR_EXTRACT_BEGIN] path=$tarPath');
    try {
      final tarBytes = await File(tarPath).readAsBytes();
      final decompressed = BZip2Decoder().decodeBytes(tarBytes);
      final archive = TarDecoder().decodeBytes(decompressed);

      for (final file in archive) {
        if (!file.isFile) {
          continue;
        }

        final normalizedPath = file.name.startsWith(_sttArchivePrefix)
            ? file.name.substring(_sttArchivePrefix.length)
            : file.name;

        String? destinationName;
        if (normalizedPath.contains('encoder')) {
          destinationName = AppConstants.sttEncoderFile;
        } else if (normalizedPath.contains('decoder')) {
          destinationName = AppConstants.sttDecoderFile;
        } else if (normalizedPath.contains('joiner')) {
          destinationName = AppConstants.sttJoinerFile;
        } else if (normalizedPath == 'tokens.txt') {
          destinationName = AppConstants.sttTokensFile;
        }

        if (destinationName == null) {
          logEvent(_tag, '[STT_TAR_SKIP_ENTRY] $normalizedPath');
          continue;
        }

        final destination = File(p.join(targetDir.path, destinationName));
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(file.content as List<int>);
        logEvent(_tag, '[STT_TAR_EXTRACTED] $destinationName');
      }

      final invalidAssets = await _sttInvalidAssets(targetDir);
      if (invalidAssets.isNotEmpty) {
        throw VoiceAssetException(
          'Verifica STT fallita: ${invalidAssets.join(", ")} non sono validi.',
        );
      }

      logEvent(_tag, '[STT_TAR_EXTRACT_COMPLETE]');
      onProgress(0.95);
    } catch (error) {
      await _cleanupSttFiles(targetDir);
      if (error is VoiceAssetException) {
        rethrow;
      }
      throw VoiceAssetException('Estrazione STT tar fallita: $error');
    } finally {
      final tarFile = File(tarPath);
      if (await tarFile.exists()) {
        await tarFile.delete();
        logEvent(_tag, '[STT_TAR_CLEANUP]');
      }
    }

    onProgress(1.0);
  }

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _ttsAssetsComplete(targetDir)) {
      logEvent(_tag, '[TTS_TAR_SKIP] all TTS assets valid');
      onProgress(1.0);
      return;
    }

    logEvent(_tag, '[TTS_TAR_CLEANUP_SCHEDULED]');
    await _cleanupTtsFiles(targetDir);

    final tarPath = p.join(targetDir.path, _ttsTarFileName);
    await _downloadFile(
      url: AppConstants.ttsPaolaTarUrl,
      destPath: tarPath,
      expectedBytes: AppConstants.ttsPaolaTarExpectedBytes,
      tag: 'TTS_TAR',
      onProgress: (value) => onProgress((value * 0.8).clamp(0.0, 0.8)),
    );

    logEvent(_tag, '[TTS_TAR_EXTRACT_BEGIN] path=$tarPath');
    try {
      final tarBytes = await File(tarPath).readAsBytes();
      final decompressed = BZip2Decoder().decodeBytes(tarBytes);
      final archive = TarDecoder().decodeBytes(decompressed);

      for (final file in archive) {
        final normalizedPath = file.name.startsWith(_ttsArchivePrefix)
            ? file.name.substring(_ttsArchivePrefix.length)
            : file.name;

        if (normalizedPath.isEmpty) {
          continue;
        }

        final destinationPath = normalizedPath == 'tokens.txt'
            ? p.join(targetDir.path, AppConstants.ttsTokensFile)
            : p.join(targetDir.path, normalizedPath);

        if (file.isFile) {
          final destination = File(destinationPath);
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(file.content as List<int>);
          logEvent(_tag, '[TTS_TAR_EXTRACTED] $normalizedPath');
        } else {
          await Directory(destinationPath).create(recursive: true);
          logEvent(_tag, '[TTS_TAR_DIR] $normalizedPath');
        }
      }

      final invalidAssets = await _ttsInvalidAssets(targetDir);
      if (invalidAssets.isNotEmpty) {
        throw VoiceAssetException(
          'Verifica TTS fallita: ${invalidAssets.join(", ")} non sono validi.',
        );
      }

      logEvent(_tag, '[TTS_TAR_EXTRACT_COMPLETE]');
      onProgress(0.95);
    } catch (error) {
      await _cleanupTtsFiles(targetDir);
      if (error is VoiceAssetException) {
        rethrow;
      }
      throw VoiceAssetException('Estrazione TTS tar fallita: $error');
    } finally {
      final tarFile = File(tarPath);
      if (await tarFile.exists()) {
        await tarFile.delete();
        logEvent(_tag, '[TTS_TAR_CLEANUP]');
      }
    }

    onProgress(1.0);
  }

  Future<void> _downloadFile({
    required String url,
    required String destPath,
    required int expectedBytes,
    required String tag,
    required Function(double) onProgress,
  }) async {
    final destination = File(destPath);
    if (await destination.exists()) {
      await destination.delete();
    }

    logEvent(_tag, '[${tag}_DOWNLOAD_BEGIN] url=$url');

    try {
      await _dio.download(
        url,
        destPath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          final denominator = total > 0 ? total : expectedBytes;
          onProgress((received / denominator).clamp(0.0, 1.0).toDouble());
        },
      );
      logEvent(_tag, '[${tag}_DOWNLOAD_COMPLETE]');
    } on DioException catch (error) {
      if (await destination.exists()) {
        await destination.delete();
      }
      final statusCode = error.response?.statusCode;
      throw VoiceAssetException(
        statusCode == null
            ? 'Download $tag fallito. ${error.message ?? "Errore di rete"}'
            : 'Download $tag fallito (HTTP $statusCode).',
      );
    } catch (error) {
      if (await destination.exists()) {
        await destination.delete();
      }
      throw VoiceAssetException('Download $tag fallito. $error');
    }
  }

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN]');
    final targetDir = await _pathResolver.privateModelsDirectory();

    final missing = <String>[];
    final sttInvalidAssets = await _sttInvalidAssets(targetDir);
    if (sttInvalidAssets.isNotEmpty) {
      missing.addAll(sttInvalidAssets);
    }
    final ttsInvalidAssets = await _ttsInvalidAssets(targetDir);
    if (ttsInvalidAssets.isNotEmpty) {
      missing.addAll(ttsInvalidAssets);
    }

    if (missing.isNotEmpty) {
      final message =
          'Risorse vocali mancanti o non valide: ${missing.join("; ")}. '
          'Riprova il download dei modelli vocali.';
      logEvent(_tag, '[ASSET_VALIDATION_FAIL] $message');
      throw VoiceAssetException(message);
    }

    logEvent(_tag, '[ASSET_VALIDATION_COMPLETE]');
  }

  Future<Directory> _ensureTargetDirectory() async {
    final targetDir = await _pathResolver.privateModelsDirectory();
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }
}
