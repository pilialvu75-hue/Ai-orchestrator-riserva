import 'dart:io';
import 'dart:isolate';

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

/// Runs archive extraction away from Flutter's UI isolate.
///
/// Nemotron is a large archive. Extracting it synchronously on the
/// Flutter isolate can make Android report the application as unresponsive.
Future<void> _extractArchiveInWorker(
  String archivePath,
  String destinationPath,
) async {
  await extractFileToDisk(
    archivePath,
    destinationPath,
  );
}

class VoiceModelDownloader with RuntimeEventEmitter {
  VoiceModelDownloader({
    Dio? dio,
    RuntimeModelPathResolver? pathResolver,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout:
                    const Duration(seconds: 30),
                receiveTimeout:
                    const Duration(hours: 2),
                sendTimeout:
                    const Duration(seconds: 30),
                followRedirects: true,
                maxRedirects: 10,
              ),
            ),
        _pathResolver =
            pathResolver ??
                const RuntimeModelPathResolver();

  static const String _tag = 'VOICE_DOWNLOAD';

  // ---------------------------------------------------------------------------
  // Nemotron 3.5 validation
  // ---------------------------------------------------------------------------

  static const int _minSttEncoderBytes =
      600 * 1024 * 1024;

  static const int _minSttDecoderBytes =
      10 * 1024 * 1024;

  static const int _minSttJoinerBytes =
      8 * 1024 * 1024;

  static const int _minSttTokensBytes =
      64 * 1024;

  // ---------------------------------------------------------------------------
  // TTS validation
  // ---------------------------------------------------------------------------

  static const int _minTtsModelBytes =
      20 * 1024 * 1024;

  static const int _minTtsTokensBytes = 256;

  // ---------------------------------------------------------------------------
  // Nemotron archive file names
  // ---------------------------------------------------------------------------

  static const String _sttEncoderMarker =
      'encoder.int8.onnx';

  static const String _sttDecoderMarker =
      'decoder.int8.onnx';

  static const String _sttJoinerMarker =
      'joiner.int8.onnx';

  final Dio _dio;
  final RuntimeModelPathResolver _pathResolver;

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  Future<bool> checkAndRequestPermissions() async {
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_BEGIN]',
    );

    if (!Platform.isAndroid) {
      logEvent(
        _tag,
        '[PERMISSION_REQUEST_RESULT] not android',
      );

      return true;
    }

    // Runtime assets are stored in app-private storage.
    // No external-storage permission is required.
    logEvent(
      _tag,
      '[PERMISSION_REQUEST_RESULT] '
      'using app-private storage',
    );

    return true;
  }

  // ---------------------------------------------------------------------------
  // Public download pipeline
  // ---------------------------------------------------------------------------

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir =
        await _ensureTargetDirectory();

    onProgress(0.0);

    // STT = first 50% of total operation.
    await _downloadAndExtractSttTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (value * 0.5)
              .clamp(0.0, 0.5),
        );
      },
    );

    // TTS = second 50%.
    await _downloadAndExtractTtsTar(
      targetDir: targetDir,
      onProgress: (value) {
        onProgress(
          (0.5 + value * 0.5)
              .clamp(0.0, 1.0),
        );
      },
    );

    await validateDownloadedAssets();

    onProgress(1.0);

    logEvent(
      _tag,
      '[DOWNLOAD_COMPLETE] '
      'voice assets ready',
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
    final partialFile =
        File(partialPath);

    var existingBytes = 0;

    if (await partialFile.exists()) {
      existingBytes =
          await partialFile.length();

      if (existingBytes > 0) {
        logEvent(
          _tag,
          '[${assetName}_RESUME] '
          'partial=$existingBytes',
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
        '[${assetName}_DOWNLOAD_INTERRUPTED] '
        'partial preserved',
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
        '[${assetName}_DOWNLOAD_INTERRUPTED] '
        'partial preserved',
      );

      throw VoiceAssetException(
        'Download $assetName interrotto: '
        '$error. '
        'Il download riprenderà dal punto raggiunto.',
      );
    }

    final completedBytes =
        await partialFile.length();

    if (completedBytes <= 0) {
      throw VoiceAssetException(
        'Download $assetName terminato '
        'con file vuoto.',
      );
    }

    // expectedBytes is only a fallback when the HTTP server does not
    // provide Content-Length/Content-Range. It must never be used as
    // a fabricated hard requirement for the final archive.
    //
    // The authoritative validation happens after extraction, where
    // the expected Nemotron encoder/decoder/joiner/tokens files are
    // checked for existence and minimum valid size.

    final destination =
        File(destinationPath);

    if (await destination.exists()) {
      await destination.delete();
    }

    await partialFile.rename(
      destinationPath,
    );

    logEvent(
      _tag,
      '[${assetName}_DOWNLOAD_COMPLETE] '
      'bytes=$completedBytes',
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
    final response =
        await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType:
            ResponseType.stream,
        followRedirects: true,
        maxRedirects: 10,
        headers: {
          HttpHeaders.rangeHeader:
              'bytes=$existingBytes-',
        },
        validateStatus: (status) {
          return status == HttpStatus.ok ||
              status ==
                  HttpStatus.partialContent ||
              status ==
                  HttpStatus
                      .requestedRangeNotSatisfiable;
        },
      ),
    );

    final status =
        response.statusCode;

    if (status ==
        HttpStatus.partialContent) {
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

    if (status ==
        HttpStatus
            .requestedRangeNotSatisfiable) {
      final total =
          _totalBytesFromContentRange(
        response,
      );

      if (total != null &&
          existingBytes >= total) {
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

    if (status == HttpStatus.ok) {
      // The server ignored the Range request and returned the complete
      // object. Never append a full 200 response to the existing .part,
      // because that would corrupt the archive.
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
      'Server HTTP inatteso durante '
      'resume $assetName: $status',
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

    final rangeTotal =
        _totalBytesFromContentRange(
      response,
    );

    final responseLength =
        _contentLength(response);

    final totalBytes =
        rangeTotal ??
            (responseLength != null
                ? existingBytes +
                    responseLength
                : expectedBytes);

    final sink =
        partialFile.openWrite(
      mode: FileMode.append,
    );

    var receivedBytes =
        existingBytes;

    try {
      await for (final chunk
          in body.stream) {
        sink.add(chunk);

        receivedBytes +=
            chunk.length;

        if (totalBytes > 0) {
          onProgress(
            (receivedBytes /
                    totalBytes)
                .clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    final declaredTotal =
        _totalBytesFromContentRange(
      response,
    );

    if (declaredTotal != null &&
        receivedBytes < declaredTotal) {
      throw VoiceAssetException(
        'Download $assetName interrotto: '
        '$receivedBytes / '
        '$declaredTotal bytes. '
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

    final response =
        await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType:
            ResponseType.stream,
        followRedirects: true,
        maxRedirects: 10,
      ),
    );

    final body = response.data;

    if (body == null) {
      throw const VoiceAssetException(
        'Risposta HTTP senza corpo '
        'durante il download.',
      );
    }

    final contentLength =
        _contentLength(response);

    final totalBytes =
        contentLength != null &&
                contentLength > 0
            ? contentLength
            : expectedBytes;

    final sink =
        partialFile.openWrite();

    var receivedBytes = 0;

    try {
      await for (final chunk
          in body.stream) {
        sink.add(chunk);

        receivedBytes +=
            chunk.length;

        if (totalBytes > 0) {
          onProgress(
            (receivedBytes /
                    totalBytes)
                .clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // If the server explicitly declared a Content-Length, it is the
    // authoritative size of this HTTP response. A short response means
    // the download was interrupted and the .part must be preserved.
    if (contentLength != null &&
        contentLength > 0 &&
        receivedBytes <
            contentLength) {
      throw VoiceAssetException(
        'Download $assetName interrotto: '
        '$receivedBytes / '
        '$contentLength bytes. '
        'Il parziale è stato conservato.',
      );
    }

    if (receivedBytes <= 0) {
      throw VoiceAssetException(
        'Download $assetName ha prodotto '
        'un file vuoto.',
      );
    }

    onProgress(1.0);
  }

  int? _contentLength(
    Response<ResponseBody> response,
  ) {
    final value =
        response.headers.value(
      HttpHeaders.contentLengthHeader,
    );

    return int.tryParse(
      value ?? '',
    );
  }

  int? _totalBytesFromContentRange(
    Response<ResponseBody> response,
  ) {
    final value =
        response.headers.value(
      HttpHeaders.contentRangeHeader,
    );

    if (value == null) {
      return null;
    }

    final slashIndex =
        value.lastIndexOf('/');

    if (slashIndex < 0) {
      return null;
    }

    final total =
        value
            .substring(
              slashIndex + 1,
            )
            .trim();

    if (total == '*') {
      return null;
    }

    return int.tryParse(total);
  }

  // ===========================================================================
  // STT — NEMOTRON
  // ===========================================================================

  Future<bool> _sttAssetsComplete(
    Directory targetDir,
  ) async {
    final requirements =
        <String, int>{
      AppConstants.sttEncoderFile:
          _minSttEncoderBytes,
      AppConstants.sttDecoderFile:
          _minSttDecoderBytes,
      AppConstants.sttJoinerFile:
          _minSttJoinerBytes,
      AppConstants.sttTokensFile:
          _minSttTokensBytes,
    };

    for (final entry
        in requirements.entries) {
      final file = File(
        p.join(
          targetDir.path,
          entry.key,
        ),
      );

      if (!await file.exists()) {
        return false;
      }

      final length =
          await file.length();

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
    if (await _sttAssetsComplete(
      targetDir,
    )) {
      logEvent(
        _tag,
        '[STT_SKIP] assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final archiveName =
        'sherpa-onnx-nemotron-3.5-'
        'asr-streaming-0.6b-560ms-'
        'int8-2026-06-11.tar.bz2';

    final tarPath =
        p.join(
          targetDir.path,
          archiveName,
        );

    final partialPath =
        '$tarPath.part';

    await _downloadResumable(
      url:
          AppConstants.sttNemotronTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants
              .sttNemotronTarExpectedBytes,
      onProgress: onProgress,
      assetName: 'STT_NEMOTRON',
    );

    final extractDir =
        Directory(
      p.join(
        targetDir.path,
        '.stt_extract_tmp',
      ),
    );

    if (await extractDir.exists()) {
      await extractDir.delete(
        recursive: true,
      );
    }

    await extractDir.create(
      recursive: true,
    );

    try {
      await Isolate.run(
        () => _extractArchiveInWorker(
          tarPath,
          extractDir.path,
        ),
      );

      final files =
          await extractDir
              .list(
                recursive: true,
                followLinks: false,
              )
              .where(
                (entity) =>
                    entity is File,
              )
              .cast<File>()
              .toList();

      File? encoder;
      File? decoder;
      File? joiner;
      File? tokens;

      for (final file in files) {
        final name =
            p.basename(file.path);

        if (name ==
            _sttEncoderMarker) {
          encoder = file;
        } else if (name ==
            _sttDecoderMarker) {
          decoder = file;
        } else if (name ==
            _sttJoinerMarker) {
          joiner = file;
        } else if (name ==
            'tokens.txt') {
          tokens = file;
        }
      }

      if (encoder == null ||
          decoder == null ||
          joiner == null ||
          tokens == null) {
        throw const VoiceAssetException(
          'Archivio Nemotron estratto '
          'ma contiene file STT incompleti '
          'o con nomi inattesi.',
        );
      }

      final encoderBytes =
          await encoder.length();
      final decoderBytes =
          await decoder.length();
      final joinerBytes =
          await joiner.length();
      final tokensBytes =
          await tokens.length();

      if (encoderBytes <
              _minSttEncoderBytes ||
          decoderBytes <
              _minSttDecoderBytes ||
          joinerBytes <
              _minSttJoinerBytes ||
          tokensBytes <
              _minSttTokensBytes) {
        throw const VoiceAssetException(
          'Archivio Nemotron estratto '
          'ma uno o più asset STT '
          'sono troppo piccoli.',
        );
      }

      final destinationEncoder =
          File(
        p.join(
          targetDir.path,
          AppConstants.sttEncoderFile,
        ),
      );

      final destinationDecoder =
          File(
        p.join(
          targetDir.path,
          AppConstants.sttDecoderFile,
        ),
      );

      final destinationJoiner =
          File(
        p.join(
          targetDir.path,
          AppConstants.sttJoinerFile,
        ),
      );

      final destinationTokens =
          File(
        p.join(
          targetDir.path,
          AppConstants.sttTokensFile,
        ),
      );

      for (final destination in [
        destinationEncoder,
        destinationDecoder,
        destinationJoiner,
        destinationTokens,
      ]) {
        if (await destination.exists()) {
          await destination.delete();
        }
      }

      await encoder.copy(
        destinationEncoder.path,
      );

      await decoder.copy(
        destinationDecoder.path,
      );

      await joiner.copy(
        destinationJoiner.path,
      );

      await tokens.copy(
        destinationTokens.path,
      );
    } catch (error) {
      if (error is VoiceAssetException) {
        rethrow;
      }

      throw VoiceAssetException(
        'Estrazione STT Nemotron fallita: '
        '$error',
      );
    } finally {
      final archiveFile =
          File(tarPath);

      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }

      if (await extractDir.exists()) {
        await extractDir.delete(
          recursive: true,
        );
      }
    }

    if (!await _sttAssetsComplete(
      targetDir,
    )) {
      throw const VoiceAssetException(
        'STT Nemotron non valido dopo '
        'l’installazione degli asset.',
      );
    }

    logEvent(
      _tag,
      '[STT_READY] '
      'Nemotron assets installed',
    );

    onProgress(1.0);
  }

  // ===========================================================================
  // TTS — existing pipeline
  // ===========================================================================

  Future<void> _downloadAndExtractTtsTar({
    required Directory targetDir,
    required Function(double) onProgress,
  }) async {
    final modelFile = File(
      p.join(
        targetDir.path,
        AppConstants.ttsModelFile,
      ),
    );

    final tokensFile = File(
      p.join(
        targetDir.path,
        AppConstants.ttsTokensFile,
      ),
    );

    final espeakDir = Directory(
      p.join(
        targetDir.path,
        AppConstants.ttsEspeakDataDir,
      ),
    );

    final modelReady =
        await modelFile.exists() &&
            await modelFile.length() >=
                _minTtsModelBytes;

    final tokensReady =
        await tokensFile.exists() &&
            await tokensFile.length() >=
                _minTtsTokensBytes;

    final espeakReady =
        await espeakDir.exists();

    if (modelReady &&
        tokensReady &&
        espeakReady) {
      logEvent(
        _tag,
        '[TTS_SKIP] assets already valid',
      );

      onProgress(1.0);
      return;
    }

    final archiveName =
        'vits-piper-it_IT-paola-medium.tar.bz2';

    final tarPath =
        p.join(
          targetDir.path,
          archiveName,
        );

    final partialPath =
        '$tarPath.part';

    await _downloadResumable(
      url:
          AppConstants.ttsPaolaTarUrl,
      destinationPath: tarPath,
      partialPath: partialPath,
      expectedBytes:
          AppConstants.ttsPaolaTarExpectedBytes,
      onProgress: onProgress,
      assetName: 'TTS_PAOLA',
    );

    final extractDir =
        Directory(
      p.join(
        targetDir.path,
        '.tts_extract_tmp',
      ),
    );

    if (await extractDir.exists()) {
      await extractDir.delete(
        recursive: true,
      );
    }

    await extractDir.create(
      recursive: true,
    );

    try {
      await Isolate.run(
        () => _extractArchiveInWorker(
          tarPath,
          extractDir.path,
        ),
      );

      final files =
          await extractDir
              .list(
                recursive: true,
                followLinks: false,
              )
              .where(
                (entity) =>
                    entity is File,
              )
              .cast<File>()
              .toList();

      File? model;
      File? tokens;
      Directory? espeak;

      for (final file in files) {
        final name =
            p.basename(file.path);

        if (name ==
            AppConstants.ttsModelFile) {
          model = file;
        } else if (name ==
            AppConstants.ttsTokensFile) {
          tokens = file;
        }
      }

      for (final entity
          in await extractDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Directory &&
            p.basename(entity.path) ==
                AppConstants
                    .ttsEspeakDataDir) {
          espeak = entity;
          break;
        }
      }

      if (model == null ||
          tokens == null ||
          espeak == null) {
        throw const VoiceAssetException(
          'Archivio TTS Paola estratto '
          'ma contiene asset incompleti.',
        );
      }

      if (await model.length() <
              _minTtsModelBytes ||
          await tokens.length() <
              _minTtsTokensBytes) {
        throw const VoiceAssetException(
          'Asset TTS Paola troppo piccoli.',
        );
      }

      if (await modelFile.exists()) {
        await modelFile.delete();
      }

      if (await tokensFile.exists()) {
        await tokensFile.delete();
      }

      if (await espeakDir.exists()) {
        await espeakDir.delete(
          recursive: true,
        );
      }

      await model.copy(
        modelFile.path,
      );

      await tokens.copy(
        tokensFile.path,
      );

      await _copyDirectory(
        espeak,
        espeakDir,
      );
    } catch (error) {
      if (error is VoiceAssetException) {
        rethrow;
      }

      throw VoiceAssetException(
        'Estrazione TTS Paola fallita: '
        '$error',
      );
    } finally {
      final archiveFile =
          File(tarPath);

      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }

      if (await extractDir.exists()) {
        await extractDir.delete(
          recursive: true,
        );
      }
    }

    onProgress(1.0);
  }

  Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (await destination.exists()) {
      await destination.delete(
        recursive: true,
      );
    }

    await destination.create(
      recursive: true,
    );

    await for (final entity
        in source.list(
      recursive: false,
      followLinks: false,
    )) {
      final name =
          p.basename(entity.path);

      final target =
          p.join(
        destination.path,
        name,
      );

      if (entity is Directory) {
        await _copyDirectory(
          entity,
          Directory(target),
        );
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }

  // ===========================================================================
  // FINAL VALIDATION
  // ===========================================================================

  Future<void> validateDownloadedAssets() async {
    final targetDir =
        await _ensureTargetDirectory();

    if (!await _sttAssetsComplete(
      targetDir,
    )) {
      throw const VoiceAssetException(
        'Asset STT Nemotron mancanti '
        'o non validi.',
      );
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

    final ttsEspeak = Directory(
      p.join(
        targetDir.path,
        AppConstants.ttsEspeakDataDir,
      ),
    );

    if (!await ttsModel.exists() ||
        await ttsModel.length() <
            _minTtsModelBytes) {
      throw const VoiceAssetException(
        'Modello TTS Paola mancante '
        'o non valido.',
      );
    }

    if (!await ttsTokens.exists() ||
        await ttsTokens.length() <
            _minTtsTokensBytes) {
      throw const VoiceAssetException(
        'tokens.txt TTS mancante '
        'o non valido.',
      );
    }

    if (!await ttsEspeak.exists()) {
      throw const VoiceAssetException(
        'espeak-ng-data TTS mancante.',
      );
    }
  }

  // ===========================================================================
  // STORAGE
  // ===========================================================================

  Future<Directory> _ensureTargetDirectory() async {
    final directory =
        await _pathResolver.voiceModelsDirectory();

    if (!await directory.exists()) {
      await directory.create(
        recursive: true,
      );
    }

    return directory;
  }
}
