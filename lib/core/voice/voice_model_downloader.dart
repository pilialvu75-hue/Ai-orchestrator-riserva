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
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(hours: 2),
              sendTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 10,
            )),
        _pathResolver = pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';
  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(_tag, '[PERMISSION_REQUEST_BEGIN]');
    if (!Platform.isAndroid) {
      logEvent(_tag, '[PERMISSION_REQUEST_RESULT] not android');
      return true;
    }
    logEvent(_tag, '[PERMISSION_REQUEST_RESULT] using app-private storage');
    return true;
  }

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');
    onProgress(0.0);

    // Fase 1: STT (50% del progresso totale)
    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (v) => onProgress((v * 0.5).clamp(0.0, 0.5)),
    );

    // Fase 2: TTS (50% del progresso totale)
    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (v) => onProgress((0.5 + v * 0.5).clamp(0.0, 1.0)),
    );

    await validateDownloadedAssets();
    logEvent(_tag, '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}');
    onProgress(1.0);
  }

  // ── STT ────────────────────────────────────────────────────────────────────

  Future<bool> _sttAssetsComplete(Directory targetDir) async {
    final checks = <String, int>{
      AppConstants.sttEncoderFile: 100 * 1024 * 1024,
      AppConstants.sttDecoderFile: 200 * 1024,
      AppConstants.sttJoinerFile: 10 * 1024 * 1024,
      AppConstants.sttTokensFile: 1024,
    };
    for (final e in checks.entries) {
      final f = File(p.join(targetDir.path, e.key));
      if (!await f.exists() || await f.length() < e.value) return false;
    }
    return true;
  }

  Future<void> _cleanupSttFiles(Directory targetDir) async {
    for (final name in [
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ]) {
      final f = File(p.join(targetDir.path, name));
      if (await f.exists()) {
        await f.delete();
        logEvent(_tag, '[CLEANUP] deleted $name');
      }
      final part = File('${f.path}.part');
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _sttAssetsComplete(targetDir)) {
      logEvent(_tag, '[STT_SKIP] all STT assets already valid');
      onProgress(1.0);
      return;
    }

    // Pulisce file parziali prima di ricominciare.
    await _cleanupSttFiles(targetDir);

    final tarPath = p.join(
      targetDir.path,
      'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2',
    );

    // Download
    logEvent(_tag, '[STT_DOWNLOAD_BEGIN] url=${AppConstants.sttZipformerTarUrl}');
    try {
      await _dio.download(
        AppConstants.sttZipformerTarUrl,
        tarPath,
        deleteOnError: true,
        options: Options(followRedirects: true, maxRedirects: 10),
        onReceiveProgress: (received, total) {
          final denom = total > 0
              ? total
              : AppConstants.sttZipformerTarExpectedBytes;
          onProgress((received / denom * 0.8).clamp(0.0, 0.8));
        },
      );
      logEvent(_tag, '[STT_DOWNLOAD_COMPLETE] path=$tarPath');
    } on DioException catch (e) {
      if (await File(tarPath).exists()) await File(tarPath).delete();
      throw VoiceAssetException(
        'Download STT fallito (HTTP ${e.response?.statusCode ?? "?"}): '
        '${e.message ?? "errore di rete"}',
      );
    } catch (e) {
      if (await File(tarPath).exists()) await File(tarPath).delete();
      throw VoiceAssetException('Download STT fallito: $e');
    }

    // Estrazione
    onProgress(0.85);
    logEvent(_tag, '[STT_EXTRACT_BEGIN]');
    try {
      final bytes = await File(tarPath).readAsBytes();
      final decompressed = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(decompressed);

      const prefix = 'sherpa-onnx-streaming-zipformer-en-2023-06-26/';
      for (final file in archive) {
        if (!file.isFile) continue;
        var name = file.name;
        if (name.startsWith(prefix)) name = name.substring(prefix.length);

        String? destName;
        if (name.contains('encoder')) {
          destName = AppConstants.sttEncoderFile;
        } else if (name.contains('decoder')) {
          destName = AppConstants.sttDecoderFile;
        } else if (name.contains('joiner')) {
          destName = AppConstants.sttJoinerFile;
        } else if (name == 'tokens.txt') {
          destName = AppConstants.sttTokensFile;
        } else {
          continue; // salta test_wavs, README, script
        }

        final dest = File(p.join(targetDir.path, destName));
        await dest.writeAsBytes(file.content as List<int>);
        logEvent(
          _tag,
          '[STT_EXTRACTED] $destName (${await dest.length()} bytes)',
        );
      }
      onProgress(0.95);
    } catch (e) {
      throw VoiceAssetException('Estrazione STT fallita: $e');
    } finally {
      final tar = File(tarPath);
      if (await tar.exists()) {
        await tar.delete();
        logEvent(_tag, '[STT_TAR_CLEANUP]');
      }
    }

    // Verifica post-estrazione
    final invalid = <String>[];
    final postChecks = <String, int>{
      AppConstants.sttEncoderFile: 100 * 1024 * 1024,
      AppConstants.sttDecoderFile: 200 * 1024,
      AppConstants.sttJoinerFile: 10 * 1024 * 1024,
      AppConstants.sttTokensFile: 1024,
    };
    for (final e in postChecks.entries) {
      final f = File(p.join(targetDir.path, e.key));
      if (!await f.exists() || await f.length() < e.value) {
        invalid.add('${e.key} (${await f.exists() ? await f.length() : 0} bytes)');
      }
    }
    if (invalid.isNotEmpty) {
      throw VoiceAssetException(
        'Verifica STT fallita: ${invalid.join("; ")} non sono validi.',
      );
    }

    logEvent(_tag, '[STT_EXTRACT_COMPLETE] all STT files valid');
    onProgress(1.0);
  }

  // ── TTS ────────────────────────────────────────────────────────────────────

  Future<bool> _ttsAssetsComplete(Directory targetDir) async {
    final model = File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final tokens = File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeak =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));
    if (!await model.exists() || await model.length() < 50 * 1024 * 1024) {
      return false;
    }
    if (!await tokens.exists() || await tokens.length() == 0) return false;
    if (!await espeak.exists()) return false;
    return true;
  }

  Future<void> _cleanupTtsFiles(Directory targetDir) async {
    for (final name in [
      AppConstants.ttsModelFile,
      AppConstants.ttsTokensFile,
    ]) {
      final f = File(p.join(targetDir.path, name));
      if (await f.exists()) {
        await f.delete();
        logEvent(_tag, '[CLEANUP] deleted $name');
      }
    }
    final espeak =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));
    if (await espeak.exists()) {
      await espeak.delete(recursive: true);
      logEvent(_tag, '[CLEANUP] deleted espeak-ng-data/');
    }
  }

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _ttsAssetsComplete(targetDir)) {
      logEvent(_tag, '[TTS_SKIP] all TTS assets already valid');
      onProgress(1.0);
      return;
    }

    await _cleanupTtsFiles(targetDir);

    final tarPath = p.join(
      targetDir.path,
      'vits-piper-it_IT-paola-medium.tar.bz2',
    );

    // Download
    logEvent(_tag, '[TTS_DOWNLOAD_BEGIN] url=${AppConstants.ttsPaolaTarUrl}');
    try {
      await _dio.download(
        AppConstants.ttsPaolaTarUrl,
        tarPath,
        deleteOnError: true,
        options: Options(followRedirects: true, maxRedirects: 10),
        onReceiveProgress: (received, total) {
          final denom = total > 0
              ? total
              : AppConstants.ttsPaolaTarExpectedBytes;
          onProgress((received / denom * 0.8).clamp(0.0, 0.8));
        },
      );
      logEvent(_tag, '[TTS_DOWNLOAD_COMPLETE] path=$tarPath');
    } on DioException catch (e) {
      if (await File(tarPath).exists()) await File(tarPath).delete();
      throw VoiceAssetException(
        'Download TTS fallito (HTTP ${e.response?.statusCode ?? "?"}): '
        '${e.message ?? "errore di rete"}',
      );
    } catch (e) {
      if (await File(tarPath).exists()) await File(tarPath).delete();
      throw VoiceAssetException('Download TTS fallito: $e');
    }

    // Estrazione
    onProgress(0.85);
    logEvent(_tag, '[TTS_EXTRACT_BEGIN]');
    try {
      final bytes = await File(tarPath).readAsBytes();
      final decompressed = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(decompressed);

      const prefix = 'vits-piper-it_IT-paola-medium/';
      for (final file in archive) {
        var outPath = file.name;
        if (outPath.startsWith(prefix)) {
          outPath = outPath.substring(prefix.length);
        }
        if (outPath.isEmpty) continue;

        // Rinomina tokens.txt per non confonderlo con quello STT.
        if (outPath == 'tokens.txt') {
          outPath = AppConstants.ttsTokensFile;
        }

        final destPath = p.join(targetDir.path, outPath);
        if (file.isFile) {
          final dest = File(destPath);
          await dest.parent.create(recursive: true);
          await dest.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(destPath).create(recursive: true);
        }
      }
      onProgress(0.95);
    } catch (e) {
      throw VoiceAssetException('Estrazione TTS fallita: $e');
    } finally {
      final tar = File(tarPath);
      if (await tar.exists()) {
        await tar.delete();
        logEvent(_tag, '[TTS_TAR_CLEANUP]');
      }
    }

    // Verifica post-estrazione
    if (!await _ttsAssetsComplete(targetDir)) {
      throw VoiceAssetException(
        'Verifica TTS fallita: file mancanti dopo estrazione.',
      );
    }

    logEvent(_tag, '[TTS_EXTRACT_COMPLETE] all TTS files valid');
    onProgress(1.0);
  }

  // ── Validazione pubblica ────────────────────────────────────────────────────

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN]');
    final targetDir = await _pathResolver.privateModelsDirectory();
    final missing = <String>[];

    final sttChecks = <String, int>{
      AppConstants.sttEncoderFile: 100 * 1024 * 1024,
      AppConstants.sttDecoderFile: 200 * 1024,
      AppConstants.sttJoinerFile: 10 * 1024 * 1024,
      AppConstants.sttTokensFile: 1024,
    };
    for (final e in sttChecks.entries) {
      final f = File(p.join(targetDir.path, e.key));
      if (!await f.exists() || await f.length() < e.value) {
        missing.add(e.key);
      }
    }

    final ttsModel = File(p.join(targetDir.path, AppConstants.ttsModelFile));
    final ttsTokens = File(p.join(targetDir.path, AppConstants.ttsTokensFile));
    final espeak =
        Directory(p.join(targetDir.path, AppConstants.ttsEspeakDataDir));

    if (!await ttsModel.exists() ||
        await ttsModel.length() < 50 * 1024 * 1024) {
      missing.add(AppConstants.ttsModelFile);
    }
    if (!await ttsTokens.exists() || await ttsTokens.length() == 0) {
      missing.add(AppConstants.ttsTokensFile);
    }
    if (!await espeak.exists()) {
      missing.add(AppConstants.ttsEspeakDataDir);
    }

    if (missing.isNotEmpty) {
      final msg =
          'Risorse vocali mancanti o non valide: ${missing.join(", ")}. '
          'Riprova il download dei modelli vocali.';
      logEvent(_tag, '[ASSET_VALIDATION_FAIL] $msg');
      throw VoiceAssetException(msg);
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
