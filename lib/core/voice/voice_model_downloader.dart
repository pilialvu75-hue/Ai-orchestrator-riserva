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
        _pathResolver =
            pathResolver ?? const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(_tag, '[PERMISSION_REQUEST_BEGIN]');

    if (!Platform.isAndroid) {
      logEvent(_tag, '[PERMISSION_REQUEST_RESULT] not android');
      return true;
    }

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

    logEvent(
      _tag,
      '[DOWNLOAD_START] targetDir=${targetDir.path}',
    );

    onProgress(0.0);

    // STT = 50% del progresso complessivo.
    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (value * 0.5).clamp(0.0, 0.5),
        );
      },
    );

    // TTS = 50% del progresso complessivo.
    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (0.5 + value * 0.5).clamp(0.0, 1.0),
        );
      },
    );

    await validateDownloadedAssets();

    logEvent(
      _tag,
      '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}',
    );

    onProgress(1.0);
  }

  // ---------------------------------------------------------------------------
  // Resumable download
  // ---------------------------------------------------------------------------

  Future<void> _downloadResumable({
    required String url,
    required String destinationPath,
    required String partialPath,
    required int expectedBytes,
    required Function(double) onProgress,
    required String assetName,
  }) async {
    final partialFile = File(partialPath);

    var existingBytes = 0;

    if (await partialFile.exists()) {
      existingBytes = await partialFile.length();

      if (existingBytes >= expectedBytes) {
        logEvent(
          _tag,
          '[$assetName_RESUME] partial file already has '
          '$existingBytes bytes',
        );
      } else if (existingBytes > 0) {
        logEvent(
          _tag,
          '[$assetName_RESUME] resuming from byte $existingBytes',
        );
      }
    }

    Future<void> downloadFromScratch() async {
      if (await partialFile.exists()) {
        await partialFile.delete();
      }

      existingBytes = 0;

      logEvent(
        _tag,
        '[$assetName_DOWNLOAD_BEGIN] starting from byte 0',
      );

      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 10,
        ),
      );

      final body = response.data;

      if (body == null) {
        throw const VoiceAssetException(
          'Risposta HTTP senza corpo durante il download.',
        );
      }

      final total = _contentLength(response) ?? expectedBytes;

      final sink = partialFile.openWrite();

      var received = 0;

      try {
        await for (final chunk in body.stream) {
          sink.add(chunk);
          received += chunk.length;

          final progress = total > 0
              ? received / total
              : 0.0;

          onProgress(
            progress.clamp(0.0, 1.0),
          );
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    }

    try {
      if (existingBytes > 0 && existingBytes < expectedBytes) {
        final response = await _dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              HttpHeaders.rangeHeader:
                  'bytes=$existingBytes-',
            },
            followRedirects: true,
            maxRedirects: 10,
            validateStatus: (status) {
              return status != null &&
                  (status == HttpStatus.ok ||
                      status == HttpStatus.partialContent ||
                      status == HttpStatus.requestedRangeNotSatisfiable);
            },
          ),
        );

        final status = response.statusCode;

        // 206 = il server supporta realmente il resume.
        if (status == HttpStatus.partialContent) {
          final body = response.data;

          if (body == null) {
            throw const VoiceAssetException(
              'Risposta HTTP 206 senza corpo.',
            );
          }

          final total =
              _totalBytesFromContentRange(response) ??
                  expectedBytes;

          final sink = partialFile.openWrite(
            mode: FileMode.append,
          );

          var received = existingBytes;

          try {
            await for (final chunk in body.stream) {
              sink.add(chunk);
              received += chunk.length;

              onProgress(
                (received / total).clamp(0.0, 1.0),
              );
            }
          } finally {
            await sink.flush();
            await sink.close();
          }

          logEvent(
            _tag,
            '[$assetName_RESUME_COMPLETE] '
            '$received bytes',
          );
        } else if (status == HttpStatus.requestedRangeNotSatisfiable) {
          logEvent(
            _tag,
            '[$assetName_RANGE_416] '
            'server rejected range; restarting',
          );

          await downloadFromScratch();
        } else {
          // 200 = il server ha ignorato Range.
          logEvent(
            _tag,
            '[$assetName_RANGE_UNSUPPORTED] '
            'server returned HTTP 200; restarting from zero',
          );

          await downloadFromScratch();
        }
      } else {
        await downloadFromScratch();
      }
    } on DioException catch (error) {
      logEvent(
        _tag,
        '[$assetName_DOWNLOAD_INTERRUPTED] '
        'partial file preserved at $partialPath',
      );

      throw VoiceAssetException(
        'Download $assetName interrotto '
        '(HTTP ${error.response?.statusCode ?? "?"}): '
        '${error.message ?? "errore di rete"}. '
        'Il download verrà ripreso dal punto raggiunto al prossimo tentativo.',
      );
    } catch (error) {
      logEvent(
        _tag,
        '[$assetName_DOWNLOAD_INTERRUPTED] '
        'partial file preserved at $partialPath',
      );

      if (error is VoiceAssetException) {
        rethrow;
      }

      throw VoiceAssetException(
        'Download $assetName interrotto: $error. '
        'Il file parziale è stato conservato.',
      );
    }

    final completedBytes = await partialFile.length();

    if (completedBytes < expectedBytes) {
      throw VoiceAssetException(
        'Download $assetName incompleto: '
        '$completedBytes / $expectedBytes bytes.',
      );
    }

    final destination = File(destinationPath);

    if (await destination.exists()) {
      await destination.delete();
    }

    await partialFile.rename(destinationPath);

    logEvent(
      _tag,
      '[$assetName_DOWNLOAD_COMPLETE] '
      '$completedBytes bytes',
    );

    onProgress(1.0);
  }

  int? _contentLength(Response<ResponseBody> response) {
    final value =
        response.headers.value(HttpHeaders.contentLengthHeader);

    return int.tryParse(value ?? '');
  }

  int? _totalBytesFromContentRange(
    Response<ResponseBody> response,
  ) {
    final value =
        response.headers.value(HttpHeaders.contentRangeHeader);

    if (value == null) return null;

    final slashIndex = value.lastIndexOf('/');

    if (slashIndex < 0) return null;

    return int.tryParse(
      value.substring(slashIndex + 1).trim(),
    );
  }

  // ---------------------------------------------------------------------------
  // STT
  // ---------------------------------------------------------------------------

  Future<bool> _sttAssetsComplete(
    Directory targetDir,
  ) async {
    final checks = <String, int>{
      AppConstants.sttEncoderFile:
          100 * 1024 * 1024,
      AppConstants.sttDecoderFile:
          200 * 1024,
      AppConstants.sttJoinerFile:
          10 * 1024 * 1024,
      AppConstants.sttTokensFile:
          1024,
    };

    for (final entry in checks.entries) {
      final file = File(
        p.join(targetDir.path, entry.key),
      );

      if (!await file.exists()) {
        return false;
      }

      if (await file.length() < entry.value) {
        return false;
      }
    }

    return true;
  }

  Future<void> _cleanupSttFiles(
    Directory targetDir,
  ) async {
    for (final name in [
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ]) {
      final file = File(
        p.join(targetDir.path, name),
      );

      if (await file.exists()) {
        await file.delete();

        logEvent(
          _tag,
          '[CLEANUP] deleted $name',
        );
      }

      final partial = File('${file.path}.part');

      if (await partial.exists()) {
        // I .part NON vengono cancellati automaticamente.
        logEvent(
          _tag,
          '[CLEANUP_SKIP_PARTIAL] preserved ${partial.path}',
        );
      }
    }
  }

  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _sttAssetsComplete(targetDir)) {
      logEvent(
        _tag,
        '[STT_SKIP] all STT assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final tarPath = p.join(
      targetDir.path,
      'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2',
    );

    final partialPath = '$tarPath.part';

    logEvent(
      _tag,
      '[STT_DOWNLOAD_BEGIN] '
      'url=${AppConstants.sttZipformerTarUrl}',
    );

    await _downloadResumable(
      url: AppConstants.sttZipformerTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants.sttZipformerTarExpectedBytes,
      assetName: 'STT',
      onProgress: (value) {
        onProgress(
          (value * 0.8).clamp(0.0, 0.8),
        );
      },
    );

    onProgress(0.85);

    logEvent(
      _tag,
      '[STT_EXTRACT_BEGIN]',
    );

    try {
      final bytes =
          await File(tarPath).readAsBytes();

      final decompressed =
          BZip2Decoder().decodeBytes(bytes);

      final archive =
          TarDecoder().decodeBytes(decompressed);

      const prefix =
          'sherpa-onnx-streaming-zipformer-en-2023-06-26/';

      for (final file in archive) {
        if (!file.isFile) continue;

        var name = file.name;

        if (name.startsWith(prefix)) {
          name = name.substring(prefix.length);
        }

        String? destinationName;

        if (name.contains('encoder')) {
          destinationName =
              AppConstants.sttEncoderFile;
        } else if (name.contains('decoder')) {
          destinationName =
              AppConstants.sttDecoderFile;
        } else if (name.contains('joiner')) {
          destinationName =
              AppConstants.sttJoinerFile;
        } else if (name == 'tokens.txt') {
          destinationName =
              AppConstants.sttTokensFile;
        } else {
          continue;
        }

        final destination = File(
          p.join(
            targetDir.path,
            destinationName,
          ),
        );

        await destination.writeAsBytes(
          file.content as List<int>,
        );

        logEvent(
          _tag,
          '[STT_EXTRACTED] '
          '$destinationName '
          '(${await destination.length()} bytes)',
        );
      }

      onProgress(0.95);
    } catch (error) {
      throw VoiceAssetException(
        'Estrazione STT fallita: $error',
      );
    } finally {
      final tar = File(tarPath);

      if (await tar.exists()) {
        await tar.delete();

        logEvent(
          _tag,
          '[STT_TAR_CLEANUP]',
        );
      }
    }

    final invalid = <String>[];

    final postChecks = <String, int>{
      AppConstants.sttEncoderFile:
          100 * 1024 * 1024,
      AppConstants.sttDecoderFile:
          200 * 1024,
      AppConstants.sttJoinerFile:
          10 * 1024 * 1024,
      AppConstants.sttTokensFile:
          1024,
    };

    for (final entry in postChecks.entries) {
      final file = File(
        p.join(targetDir.path, entry.key),
      );

      if (!await file.exists() ||
          await file.length() < entry.value) {
        invalid.add(
          '${entry.key} '
          '(${await file.exists() ? await file.length() : 0} bytes)',
        );
      }
    }

    if (invalid.isNotEmpty) {
      throw VoiceAssetException(
        'Verifica STT fallita: '
        '${invalid.join("; ")} non sono validi.',
      );
    }

    logEvent(
      _tag,
      '[STT_EXTRACT_COMPLETE] all STT files valid',
    );

    onProgress(1.0);
  }

  // ---------------------------------------------------------------------------
  // TTS
  // ---------------------------------------------------------------------------

  Future<bool> _ttsAssetsComplete(
    Directory targetDir,
  ) async {
    final model = File(
      p.join(
        targetDir.path,
        AppConstants.ttsModelFile,
      ),
    );

    final tokens = File(
      p.join(
        targetDir.path,
        AppConstants.ttsTokensFile,
      ),
    );

    final espeak = Directory(
      p.join(
        targetDir.path,
        AppConstants.ttsEspeakDataDir,
      ),
    );

    if (!await model.exists() ||
        await model.length() < 50 * 1024 * 1024) {
      return false;
    }

    if (!await tokens.exists() ||
        await tokens.length() == 0) {
      return false;
    }

    if (!await espeak.exists()) {
      return false;
    }

    return true;
  }

  Future<void> _cleanupTtsFiles(
    Directory targetDir,
  ) async {
    for (final name in [
      AppConstants.ttsModelFile,
      AppConstants.ttsTokensFile,
    ]) {
      final file = File(
        p.join(targetDir.path, name),
      );

      if (await file.exists()) {
        await file.delete();

        logEvent(
          _tag,
          '[CLEANUP] deleted $name',
        );
      }

      final partial = File('${file.path}.part');

      if (await partial.exists()) {
        logEvent(
          _tag,
          '[CLEANUP_SKIP_PARTIAL] preserved ${partial.path}',
        );
      }
    }

    final espeak = Directory(
      p.join(
        targetDir.path,
        AppConstants.ttsEspeakDataDir,
      ),
    );

    if (await espeak.exists()) {
      await espeak.delete(recursive: true);

      logEvent(
        _tag,
        '[CLEANUP] deleted espeak-ng-data/',
      );
    }
  }

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _ttsAssetsComplete(targetDir)) {
      logEvent(
        _tag,
        '[TTS_SKIP] all TTS assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final tarPath = p.join(
      targetDir.path,
      'vits-piper-it_IT-paola-medium.tar.bz2',
    );

    final partialPath = '$tarPath.part';

    logEvent(
      _tag,
      '[TTS_DOWNLOAD_BEGIN] '
      'url=${AppConstants.ttsPaolaTarUrl}',
    );

    await _downloadResumable(
      url: AppConstants.ttsPaolaTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants.ttsPaolaTarExpectedBytes,
      assetName: 'TTS',
      onProgress: (value) {
        onProgress(
          (value * 0.8).clamp(0.0, 0.8),
        );
      },
    );

    onProgress(0.85);

    logEvent(
      _tag,
      '[TTS_EXTRACT_BEGIN]',
    );

    try {
      final bytes =
          await File(tarPath).readAsBytes();

      final decompressed =
          BZip2Decoder().decodeBytes(bytes);

      final archive =
          TarDecoder().decodeBytes(decompressed);

      const prefix =
          'vits-piper-it_IT-paola-medium/';

      for (final file in archive) {
        var outputPath = file.name;

        if (outputPath.startsWith(prefix)) {
          outputPath =
              outputPath.substring(prefix.length);
        }

        if (outputPath.isEmpty) continue;

        if (outputPath == 'tokens.txt') {
          outputPath =
              AppConstants.ttsTokensFile;
        }

        final destinationPath = p.join(
          targetDir.path,
          outputPath,
        );

        if (file.isFile) {
          final destination =
              File(destinationPath);

          await destination.parent.create(
            recursive: true,
          );

          await destination.writeAsBytes(
            file.content as List<int>,
          );
        } else {
          await Directory(destinationPath)
              .create(recursive: true);
        }
      }

      onProgress(0.95);
    } catch (error) {
      throw VoiceAssetException(
        'Estrazione TTS fallita: $error',
      );
    } finally {
      final tar = File(tarPath);

      if (await tar.exists()) {
        await tar.delete();

        logEvent(
          _tag,
          '[TTS_TAR_CLEANUP]',
        );
      }
    }

    if (!await _ttsAssetsComplete(targetDir)) {
      throw const VoiceAssetException(
        'Verifica TTS fallita: '
        'file mancanti dopo estrazione.',
      );
    }

    logEvent(
      _tag,
      '[TTS_EXTRACT_COMPLETE] all TTS files valid',
    );

    onProgress(1.0);
  }

  // ---------------------------------------------------------------------------
  // Validazione pubblica
  // ---------------------------------------------------------------------------

  Future<void> validateDownloadedAssets() async {
    logEvent(
      _tag,
      '[ASSET_VALIDATION_BEGIN]',
    );

    final targetDir =
        await _pathResolver.privateModelsDirectory();

    final missing = <String>[];

    final sttChecks = <String, int>{
      AppConstants.sttEncoderFile:
          100 * 1024 * 1024,
      AppConstants.sttDecoderFile:
          200 * 1024,
      AppConstants.sttJoinerFile:
          10 * 1024 * 1024,
      AppConstants.sttTokensFile:
          1024,
    };

    for (final entry in sttChecks.entries) {
      final file = File(
        p.join(targetDir.path, entry.key),
      );

      if (!await file.exists() ||
          await file.length() < entry.value) {
        missing.add(entry.key);
      }
    }

    final ttsModel = File(
      p.join(
        targetDir.path,
        AppConstants.ttsModelFile,
      ),
    );

    final ttsTokens = File(
      p.join(
        targetDir.path,
        AppConstants.ttsTokensFile,
      ),
    );

    final espeak = Directory(
      p.join(
        targetDir.path,
        AppConstants.ttsEspeakDataDir,
      ),
    );

    if (!await ttsModel.exists() ||
        await ttsModel.length() < 50 * 1024 * 1024) {
      missing.add(
        AppConstants.ttsModelFile,
      );
    }

    if (!await ttsTokens.exists() ||
        await ttsTokens.length() == 0) {
      missing.add(
        AppConstants.ttsTokensFile,
      );
    }

    if (!await espeak.exists()) {
      missing.add(
        AppConstants.ttsEspeakDataDir,
      );
    }

    if (missing.isNotEmpty) {
      final message =
          'Risorse vocali mancanti o non valide: '
          '${missing.join(", ")}. '
          'Riprova il download dei modelli vocali.';

      logEvent(
        _tag,
        '[ASSET_VALIDATION_FAIL] $message',
      );

      throw VoiceAssetException(message);
    }

    logEvent(
      _tag,
      '[ASSET_VALIDATION_COMPLETE] '
      'all voice assets ready',
    );
  }

  Future<Directory> _ensureTargetDirectory() async {
    final targetDir =
        await _pathResolver.privateModelsDirectory();

    if (!await targetDir.exists()) {
      await targetDir.create(
        recursive: true,
      );
    }

    return targetDir;
  }
}
