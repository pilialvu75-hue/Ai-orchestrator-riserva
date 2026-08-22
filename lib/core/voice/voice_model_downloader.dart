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

  // ---------------------------------------------------------------------------
  // STT validation thresholds
  //
  // These are deliberately conservative lower bounds, not exact file sizes.
  // They protect against accepting a partially written/truncated ONNX file
  // while allowing small upstream model packaging changes.
  // ---------------------------------------------------------------------------

  static const int _minSttEncoderBytes = 50 * 1024 * 1024;
  static const int _minSttDecoderBytes = 512 * 1024;
  static const int _minSttJoinerBytes = 100 * 1024;
  static const int _minSttTokensBytes = 1024;

  // TTS is considerably smaller, but an almost-empty/truncated file must
  // never be considered a valid runtime asset.
  static const int _minTtsModelBytes = 20 * 1024 * 1024;
  static const int _minTtsTokensBytes = 256;

  // The selected streaming Zipformer configuration is:
  //
  // encoder: ...left-128.int8.onnx
  // decoder: ...left-128.onnx
  // joiner : ...left-128.int8.onnx
  //
  // This avoids accidentally installing the ~262 MB FP32 encoder.
  static const String _sttEncoderMarker =
      'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx';

  static const String _sttDecoderMarker =
      'decoder-epoch-99-avg-1-chunk-16-left-128.onnx';

  static const String _sttJoinerMarker =
      'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx';

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  Future<bool> checkAndRequestPermissions() async {
    logEvent(_tag, '[PERMISSION_REQUEST_BEGIN]');

    if (!Platform.isAndroid) {
      logEvent(
        _tag,
        '[PERMISSION_REQUEST_RESULT] not android',
      );
      return true;
    }

    // Runtime voice assets are stored in app-private storage.
    // No external-storage permission is required for this path.
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

    onProgress(0.0);

    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (value * 0.5).clamp(0.0, 0.5),
        );
      },
    );

    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (0.5 + value * 0.5).clamp(0.0, 1.0),
        );
      },
    );

    await validateDownloadedAssets();

    onProgress(1.0);

    logEvent(
      _tag,
      '[DOWNLOAD_COMPLETE] voice assets ready',
    );
  }

  // ===========================================================================
  // RESUMABLE DOWNLOAD
  // ===========================================================================

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

      if (existingBytes > 0) {
        logEvent(
          _tag,
          '[${assetName}_RESUME] partial=$existingBytes',
        );
      }
    }

    try {
      if (existingBytes > 0) {
        await _resumeDownload(
          url: url,
          partialFile: partialFile,
          existingBytes: existingBytes,
          expectedBytes: expectedBytes,
          onProgress: onProgress,
          assetName: assetName,
        );
      } else {
        await _downloadFromZero(
          url: url,
          partialFile: partialFile,
          expectedBytes: expectedBytes,
          onProgress: onProgress,
          assetName: assetName,
        );
      }
    } on DioException catch (error) {
      logEvent(
        _tag,
        '[${assetName}_DOWNLOAD_INTERRUPTED] partial preserved',
      );

      throw VoiceAssetException(
        'Download $assetName interrotto '
        '(HTTP ${error.response?.statusCode ?? "?"}): '
        '${error.message ?? "errore di rete"}. '
        'Il download riprenderà dal punto raggiunto.',
      );
    } catch (error) {
      if (error is VoiceAssetException) {
        rethrow;
      }

      logEvent(
        _tag,
        '[${assetName}_DOWNLOAD_INTERRUPTED] partial preserved',
      );

      throw VoiceAssetException(
        'Download $assetName interrotto: $error. '
        'Il download riprenderà dal punto raggiunto.',
      );
    }

    final completedBytes = await partialFile.length();

    if (completedBytes <= 0) {
      throw VoiceAssetException(
        'Download $assetName terminato con file vuoto.',
      );
    }

    final destination = File(destinationPath);

    if (await destination.exists()) {
      await destination.delete();
    }

    await partialFile.rename(destinationPath);

    logEvent(
      _tag,
      '[${assetName}_DOWNLOAD_COMPLETE] bytes=$completedBytes',
    );

    onProgress(1.0);
  }

  Future<void> _resumeDownload({
    required String url,
    required File partialFile,
    required int existingBytes,
    required int expectedBytes,
    required Function(double) onProgress,
    required String assetName,
  }) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        maxRedirects: 10,
        headers: {
          HttpHeaders.rangeHeader: 'bytes=$existingBytes-',
        },
        validateStatus: (status) {
          return status == HttpStatus.ok ||
              status == HttpStatus.partialContent ||
              status == HttpStatus.requestedRangeNotSatisfiable;
        },
      ),
    );

    final status = response.statusCode;

    if (status == HttpStatus.partialContent) {
      await _appendPartialResponse(
        response: response,
        partialFile: partialFile,
        existingBytes: existingBytes,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        assetName: assetName,
      );
      return;
    }

    if (status == HttpStatus.requestedRangeNotSatisfiable) {
      final total = _totalBytesFromContentRange(response);

      if (total != null && existingBytes >= total) {
        onProgress(1.0);
        return;
      }

      await _downloadFromZero(
        url: url,
        partialFile: partialFile,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        assetName: assetName,
      );
      return;
    }

    // Server ignored Range and returned the complete file.
    if (status == HttpStatus.ok) {
      await _downloadFromZero(
        url: url,
        partialFile: partialFile,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        assetName: assetName,
      );
      return;
    }

    throw VoiceAssetException(
      'Server HTTP inatteso durante resume $assetName: $status',
    );
  }

  Future<void> _appendPartialResponse({
    required Response<ResponseBody> response,
    required File partialFile,
    required int existingBytes,
    required int expectedBytes,
    required Function(double) onProgress,
    required String assetName,
  }) async {
    final body = response.data;

    if (body == null) {
      throw const VoiceAssetException(
        'Risposta HTTP 206 senza corpo.',
      );
    }

    final rangeTotal = _totalBytesFromContentRange(response);
    final responseLength = _contentLength(response);

    final totalBytes = rangeTotal ??
        (responseLength != null
            ? existingBytes + responseLength
            : expectedBytes);

    final sink = partialFile.openWrite(
      mode: FileMode.append,
    );

    var receivedBytes = existingBytes;

    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes > 0) {
          onProgress(
            (receivedBytes / totalBytes).clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    final declaredTotal =
        _totalBytesFromContentRange(response);

    if (declaredTotal != null &&
        receivedBytes < declaredTotal) {
      throw VoiceAssetException(
        'Download $assetName interrotto: '
        '$receivedBytes / $declaredTotal bytes. '
        'Il parziale è stato conservato.',
      );
    }

    onProgress(1.0);
  }

  Future<void> _downloadFromZero({
    required String url,
    required File partialFile,
    required int expectedBytes,
    required Function(double) onProgress,
    required String assetName,
  }) async {
    if (await partialFile.exists()) {
      await partialFile.delete();
    }

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

    final contentLength = _contentLength(response);

    final totalBytes =
        contentLength != null && contentLength > 0
            ? contentLength
            : expectedBytes;

    final sink = partialFile.openWrite();

    var receivedBytes = 0;

    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes > 0) {
          onProgress(
            (receivedBytes / totalBytes).clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (contentLength != null &&
        contentLength > 0 &&
        receivedBytes < contentLength) {
      throw VoiceAssetException(
        'Download $assetName interrotto: '
        '$receivedBytes / $contentLength bytes. '
        'Il parziale è stato conservato.',
      );
    }

    if (receivedBytes <= 0) {
      throw VoiceAssetException(
        'Download $assetName ha prodotto un file vuoto.',
      );
    }

    onProgress(1.0);
  }

  int? _contentLength(
    Response<ResponseBody> response,
  ) {
    final value = response.headers.value(
      HttpHeaders.contentLengthHeader,
    );

    return int.tryParse(value ?? '');
  }

  int? _totalBytesFromContentRange(
    Response<ResponseBody> response,
  ) {
    final value = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );

    if (value == null) {
      return null;
    }

    final slashIndex = value.lastIndexOf('/');

    if (slashIndex < 0) {
      return null;
    }

    final total =
        value.substring(slashIndex + 1).trim();

    if (total == '*') {
      return null;
    }

    return int.tryParse(total);
  }

  // ===========================================================================
  // STT
  // ===========================================================================

  Future<bool> _sttAssetsComplete(
    Directory targetDir,
  ) async {
    final requirements = <String, int>{
      AppConstants.sttEncoderFile:
          _minSttEncoderBytes,
      AppConstants.sttDecoderFile:
          _minSttDecoderBytes,
      AppConstants.sttJoinerFile:
          _minSttJoinerBytes,
      AppConstants.sttTokensFile:
          _minSttTokensBytes,
    };

    for (final entry in requirements.entries) {
      final file = File(
        p.join(targetDir.path, entry.key),
      );

      if (!await file.exists()) {
        return false;
      }

      final length = await file.length();

      if (length < entry.value) {
        return false;
      }
    }

    return true;
  }

  Future<void> _downloadAndExtractSttTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _sttAssetsComplete(targetDir)) {
      logEvent(
        _tag,
        '[STT_SKIP] assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final tarPath = p.join(
      targetDir.path,
      'sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2',
    );

    final partialPath = '$tarPath.part';

    await _downloadResumable(
      url: AppConstants.sttZipformerTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants.sttZipformerTarExpectedBytes,
      assetName: 'STT',
      onProgress: (value) {
        onProgress(
          (value * 0.75).clamp(0.0, 0.75),
        );
      },
    );

    onProgress(0.80);

    final extractionDir =
        await Directory(
      p.join(
        targetDir.path,
        '.stt_extract_tmp',
      ),
    ).create(recursive: true);

    try {
      /*
       * IMPORTANT:
       *
       * Never use:
       *
       *   File(tarPath).readAsBytes()
       *   BZip2Decoder().decodeBytes(...)
       *   TarDecoder().decodeBytes(...)
       *
       * here.
       *
       * extractFileToDisk() uses archive_io's file based path and avoids
       * keeping the compressed archive and the decompressed TAR in RAM.
       */
      await extractFileToDisk(
        tarPath,
        extractionDir.path,
      );

      onProgress(0.90);

      final files =
          await _collectFiles(extractionDir);

      final encoderSource =
          _findByBasename(
        files,
        _sttEncoderMarker,
      );

      final decoderSource =
          _findByBasename(
        files,
        _sttDecoderMarker,
      );

      final joinerSource =
          _findByBasename(
        files,
        _sttJoinerMarker,
      );

      final tokensSource =
          _findByBasename(
        files,
        AppConstants.sttTokensFile,
      );

      if (encoderSource == null ||
          decoderSource == null ||
          joinerSource == null ||
          tokensSource == null) {
        throw const VoiceAssetException(
          'Archivio STT valido ma modello INT8 '
          'left-128 non trovato.',
        );
      }

      /*
       * Validate source files BEFORE touching the runtime files.
       */
      await _requireMinimumSize(
        encoderSource,
        _minSttEncoderBytes,
        'STT encoder INT8',
      );

      await _requireMinimumSize(
        decoderSource,
        _minSttDecoderBytes,
        'STT decoder',
      );

      await _requireMinimumSize(
        joinerSource,
        _minSttJoinerBytes,
        'STT joiner INT8',
      );

      await _requireMinimumSize(
        tokensSource,
        _minSttTokensBytes,
        'STT tokens',
      );

      /*
       * Atomic replacement:
       *
       * 1. write/copy into .part
       * 2. validate
       * 3. rename to final file
       *
       * A half-written ONNX file is therefore never considered ready.
       */
      await _installAtomically(
        source: encoderSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.sttEncoderFile,
          ),
        ),
      );

      await _installAtomically(
        source: decoderSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.sttDecoderFile,
          ),
        ),
      );

      await _installAtomically(
        source: joinerSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.sttJoinerFile,
          ),
        ),
      );

      await _installAtomically(
        source: tokensSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.sttTokensFile,
          ),
        ),
      );

      onProgress(0.97);
    } catch (error) {
      if (error is VoiceAssetException) {
        rethrow;
      }

      throw VoiceAssetException(
        'Estrazione STT fallita: $error',
      );
    } finally {
      /*
       * The archive is deleted only after extraction has finished.
       * If extraction/download fails, the .part download remains available
       * for resume; the completed archive is intentionally cleaned here.
       */
      await _deleteIfExists(File(tarPath));

      if (await extractionDir.exists()) {
        await extractionDir.delete(
          recursive: true,
        );
      }
    }

    if (!await _sttAssetsComplete(targetDir)) {
      throw const VoiceAssetException(
        'Verifica STT fallita: '
        'uno o più asset sono assenti o troppo piccoli.',
      );
    }

    onProgress(1.0);

    logEvent(
      _tag,
      '[STT_READY] INT8 left-128 assets installed',
    );
  }

  // ===========================================================================
  // TTS
  // ===========================================================================

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
        await model.length() < _minTtsModelBytes) {
      return false;
    }

    if (!await tokens.exists() ||
        await tokens.length() < _minTtsTokensBytes) {
      return false;
    }

    if (!await espeak.exists()) {
      return false;
    }

    return true;
  }

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    if (await _ttsAssetsComplete(targetDir)) {
      logEvent(
        _tag,
        '[TTS_SKIP] assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final tarPath = p.join(
      targetDir.path,
      'vits-piper-it_IT-paola-medium.tar.bz2',
    );

    final partialPath = '$tarPath.part';

    await _downloadResumable(
      url: AppConstants.ttsPaolaTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants.ttsPaolaTarExpectedBytes,
      assetName: 'TTS',
      onProgress: (value) {
        onProgress(
          (value * 0.75).clamp(0.0, 0.75),
        );
      },
    );

    onProgress(0.80);

    final extractionDir =
        await Directory(
      p.join(
        targetDir.path,
        '.tts_extract_tmp',
      ),
    ).create(recursive: true);

    try {
      await extractFileToDisk(
        tarPath,
        extractionDir.path,
      );

      onProgress(0.90);

      final files =
          await _collectFiles(extractionDir);

      final modelSource =
          _findByExtension(
        files,
        '.onnx',
      );

      final tokensSource =
          _findByBasename(
        files,
        'tokens.txt',
      );

      final espeakSource =
          _findDirectory(
        extractionDir,
        AppConstants.ttsEspeakDataDir,
      );

      if (modelSource == null) {
        throw const VoiceAssetException(
          'Modello TTS ONNX non trovato nell\'archivio.',
        );
      }

      if (tokensSource == null) {
        throw const VoiceAssetException(
          'tokens.txt TTS non trovato nell\'archivio.',
        );
      }

      if (espeakSource == null) {
        throw const VoiceAssetException(
          'espeak-ng-data non trovato nell\'archivio TTS.',
        );
      }

      await _requireMinimumSize(
        modelSource,
        _minTtsModelBytes,
        'TTS model',
      );

      await _requireMinimumSize(
        tokensSource,
        _minTtsTokensBytes,
        'TTS tokens',
      );

      await _installAtomically(
        source: modelSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.ttsModelFile,
          ),
        ),
      );

      await _installAtomically(
        source: tokensSource,
        destination: File(
          p.join(
            targetDir.path,
            AppConstants.ttsTokensFile,
          ),
        ),
      );

      final destinationEspeak =
          Directory(
        p.join(
          targetDir.path,
          AppConstants.ttsEspeakDataDir,
        ),
      );

      if (await destinationEspeak.exists()) {
        await destinationEspeak.delete(
          recursive: true,
        );
      }

      await _copyDirectory(
        espeakSource,
        destinationEspeak,
      );

      onProgress(0.97);
    } catch (error) {
      if (error is VoiceAssetException) {
        rethrow;
      }

      throw VoiceAssetException(
        'Estrazione TTS fallita: $error',
      );
    } finally {
      await _deleteIfExists(File(tarPath));

      if (await extractionDir.exists()) {
        await extractionDir.delete(
          recursive: true,
        );
      }
    }

    if (!await _ttsAssetsComplete(targetDir)) {
      throw const VoiceAssetException(
        'Verifica TTS fallita: '
        'asset mancanti o troppo piccoli.',
      );
    }

    onProgress(1.0);

    logEvent(
      _tag,
      '[TTS_READY] assets installed',
    );
  }

  // ===========================================================================
  // FILESYSTEM HELPERS
  // ===========================================================================

  Future<List<File>> _collectFiles(
    Directory directory,
  ) async {
    final result = <File>[];

    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        result.add(entity);
      }
    }

    return result;
  }

  File? _findByBasename(
    List<File> files,
    String basename,
  ) {
    for (final file in files) {
      if (p.basename(file.path) == basename) {
        return file;
      }
    }

    return null;
  }

  File? _findByExtension(
    List<File> files,
    String extension,
  ) {
    /*
     * Prefer a Piper ONNX model rather than a JSON metadata file.
     */
    for (final file in files) {
      final name = p.basename(file.path);

      if (name.endsWith(extension) &&
          !name.endsWith('.onnx.json')) {
        return file;
      }
    }

    return null;
  }

  Directory? _findDirectory(
    Directory root,
    String basename,
  ) {
    final direct = Directory(
      p.join(root.path, basename),
    );

    if (direct.existsSync()) {
      return direct;
    }

    /*
     * The archive normally contains the directory directly below the
     * model root. We still search recursively so packaging changes don't
     * break the downloader.
     */
    final entities = root.listSync(
      recursive: true,
      followLinks: false,
    );

    for (final entity in entities) {
      if (entity is Directory &&
          p.basename(entity.path) == basename) {
        return entity;
      }
    }

    return null;
  }

  Future<void> _requireMinimumSize(
    File file,
    int minimumBytes,
    String description,
  ) async {
    if (!await file.exists()) {
      throw VoiceAssetException(
        '$description non trovato.',
      );
    }

    final length = await file.length();

    if (length < minimumBytes) {
      throw VoiceAssetException(
        '$description non valido: '
        '$length bytes < minimo $minimumBytes bytes.',
      );
    }
  }

  Future<void> _installAtomically({
    required File source,
    required File destination,
  }) async {
    final temporary =
        File('${destination.path}.part');

    await _deleteIfExists(temporary);

    await temporary.parent.create(
      recursive: true,
    );

    /*
     * File.copy() is streamed by dart:io and does not load the entire
     * ONNX file into the Dart heap.
     */
    await source.copy(temporary.path);

    final size = await temporary.length();

    if (size <= 0) {
      await _deleteIfExists(temporary);

      throw VoiceAssetException(
        'Installazione fallita: '
        '${destination.path} è vuoto.',
      );
    }

    await _deleteIfExists(destination);

    await temporary.rename(
      destination.path,
    );
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(
      recursive: true,
    );

    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(
        entity.path,
        from: source.path,
      );

      final target =
          p.join(destination.path, relative);

      if (entity is Directory) {
        await Directory(target).create(
          recursive: true,
        );
      } else if (entity is File) {
        await File(target).parent.create(
          recursive: true,
        );
        await entity.copy(target);
      }
    }
  }

  Future<void> _deleteIfExists(
    FileSystemEntity entity,
  ) async {
    if (await entity.exists()) {
      await entity.delete(
        recursive: entity is Directory,
      );
    }
  }

  // ===========================================================================
  // VALIDATION
  // ===========================================================================

  Future<void> validateDownloadedAssets() async {
    final targetDir =
        await _pathResolver.privateModelsDirectory();

    final missing = <String>[];

    final sttRequirements = <String, int>{
      AppConstants.sttEncoderFile:
          _minSttEncoderBytes,
      AppConstants.sttDecoderFile:
          _minSttDecoderBytes,
      AppConstants.sttJoinerFile:
          _minSttJoinerBytes,
      AppConstants.sttTokensFile:
          _minSttTokensBytes,
    };

    for (final entry in sttRequirements.entries) {
      final file = File(
        p.join(targetDir.path, entry.key),
      );

      if (!await file.exists()) {
        missing.add(entry.key);
        continue;
      }

      final length = await file.length();

      if (length < entry.value) {
        missing.add(
          '${entry.key}(truncated:$length)',
        );
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
        await ttsModel.length() < _minTtsModelBytes) {
      missing.add(
        AppConstants.ttsModelFile,
      );
    }

    if (!await ttsTokens.exists() ||
        await ttsTokens.length() < _minTtsTokensBytes) {
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
      throw VoiceAssetException(
        'Risorse vocali mancanti o non valide: '
        '${missing.join(", ")}.',
      );
    }
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
