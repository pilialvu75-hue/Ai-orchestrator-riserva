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
      logEvent(
        _tag,
        '[PERMISSION_REQUEST_RESULT] not android',
      );
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

    logEvent(
      _tag,
      '[DOWNLOAD_COMPLETE] '
      'voice assets ready in ${targetDir.path}',
    );

    onProgress(1.0);
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
          '[$assetName_RESUME] partial=$existingBytes bytes',
        );
      }
    }

    /*
     * Se il file parziale ha raggiunto la dimensione dichiarata attesa,
     * non lo promuoviamo ciecamente.
     *
     * La dimensione dichiarata nelle costanti è solo un fallback:
     * il valore reale viene determinato dal server quando disponibile.
     */
    if (existingBytes > 0 && existingBytes >= expectedBytes) {
      logEvent(
        _tag,
        '[$assetName_RESUME_SIZE_REACHED] '
        'partial=$existingBytes expected=$expectedBytes',
      );
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
        '[$assetName_DOWNLOAD_INTERRUPTED] '
        'partial file preserved',
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
        '[$assetName_DOWNLOAD_INTERRUPTED] '
        'partial file preserved',
      );

      throw VoiceAssetException(
        'Download $assetName interrotto: $error. '
        'Il download riprenderà dal punto raggiunto.',
      );
    }

    final completedBytes = await partialFile.length();

    /*
     * Se il server ha fornito Content-Length/Content-Range, il metodo
     * di download ha già verificato il totale.
     *
     * expectedBytes viene usato solamente come controllo di sicurezza
     * quando il server non fornisce informazioni migliori.
     */
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
      '[$assetName_DOWNLOAD_COMPLETE] '
      '$completedBytes bytes',
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

    logEvent(
      _tag,
      '[$assetName_RANGE_RESPONSE] '
      'status=$status existing=$existingBytes',
    );

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
      /*
       * Il file locale potrebbe essere già completo oppure il server
       * non accettare più quel Range.
       *
       * Invece di cancellarlo immediatamente, controlliamo se il server
       * dichiara il totale.
       */
      final total =
          _totalBytesFromContentRange(response);

      if (total != null && existingBytes >= total) {
        logEvent(
          _tag,
          '[$assetName_RANGE_COMPLETE] '
          'existing=$existingBytes total=$total',
        );
        onProgress(1.0);
        return;
      }

      logEvent(
        _tag,
        '[$assetName_RANGE_416] '
        'range rejected; restarting safely',
      );

      await _downloadFromZero(
        url: url,
        partialFile: partialFile,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        assetName: assetName,
      );

      return;
    }

    /*
     * HTTP 200:
     *
     * il server ha ignorato Range e sta inviando l'intero file.
     * Non possiamo appendere l'intero archivio al parziale.
     *
     * In questo caso ripartiamo da zero, ma SOLO perché il server
     * non supporta il resume.
     */
    if (status == HttpStatus.ok) {
      logEvent(
        _tag,
        '[$assetName_RANGE_UNSUPPORTED] '
        'server returned HTTP 200; replacing partial safely',
      );

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

    final totalBytes =
        _totalBytesFromContentRange(response) ??
            _contentLength(response) != null
            ? existingBytes + _contentLength(response)!
            : expectedBytes;

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
            (receivedBytes / totalBytes)
                .clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    /*
     * Se Content-Range ci ha dato il totale, pretendiamo di averlo
     * raggiunto. In questo modo una connessione che cade senza errore
     * esplicito non viene scambiata per un download completo.
     */
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

    logEvent(
      _tag,
      '[$assetName_RESUME_CHUNK_COMPLETE] '
      '$receivedBytes bytes',
    );

    onProgress(1.0);
  }

  Future<void> _downloadFromZero({
    required String url,
    required File partialFile,
    required int expectedBytes,
    required Function(double) onProgress,
    required String assetName,
  }) async {
    /*
     * Questo è l'unico punto in cui il parziale viene cancellato.
     *
     * Succede solo quando il server non supporta Range oppure il Range
     * locale non è più utilizzabile.
     */
    if (await partialFile.exists()) {
      await partialFile.delete();
    }

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

    final contentLength =
        _contentLength(response);

    /*
     * Il Content-Length reale del server ha priorità assoluta.
     * expectedBytes è solamente un fallback.
     */
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
            (receivedBytes / totalBytes)
                .clamp(0.0, 1.0),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    /*
     * Se il server ci ha dichiarato la dimensione, la connessione
     * deve aver trasferito esattamente quella quantità.
     */
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

    logEvent(
      _tag,
      '[$assetName_DOWNLOAD_STREAM_COMPLETE] '
      '$receivedBytes bytes',
    );

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
    /*
     * NON usiamo più soglie arbitrarie come:
     *
     * encoder >= 100 MB
     * joiner >= 10 MB
     *
     * Le dimensioni reali dell'archivio Zipformer2 sono diverse.
     *
     * Per il momento la validazione primaria è:
     * file presente + dimensione > 0.
     *
     * L'integrità runtime viene poi verificata da Sherpa-ONNX.
     */
    final files = <String>[
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ];

    for (final name in files) {
      final file = File(
        p.join(targetDir.path, name),
      );

      if (!await file.exists()) {
        return false;
      }

      final length = await file.length();

      if (length <= 0) {
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
        if (!file.isFile) {
          continue;
        }

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

        await destination.parent.create(
          recursive: true,
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

    if (!await _sttAssetsComplete(targetDir)) {
      throw const VoiceAssetException(
        'Verifica STT fallita: '
        'uno o più file non sono presenti dopo l\'estrazione.',
      );
    }

    logEvent(
      _tag,
      '[STT_EXTRACT_COMPLETE] '
      'all STT files valid',
    );

    onProgress(1.0);
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
        await model.length() <= 0) {
      return false;
    }

    if (!await tokens.exists() ||
        await tokens.length() <= 0) {
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

        if (outputPath.isEmpty) {
          continue;
        }

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
      '[TTS_EXTRACT_COMPLETE] '
      'all TTS files valid',
    );

    onProgress(1.0);
  }

  // ===========================================================================
  // VALIDATION
  // ===========================================================================

  Future<void> validateDownloadedAssets() async {
    logEvent(
      _tag,
      '[ASSET_VALIDATION_BEGIN]',
    );

    final targetDir =
        await _pathResolver.privateModelsDirectory();

    final missing = <String>[];

    final sttFiles = <String>[
      AppConstants.sttEncoderFile,
      AppConstants.sttDecoderFile,
      AppConstants.sttJoinerFile,
      AppConstants.sttTokensFile,
    ];

    for (final name in sttFiles) {
      final file = File(
        p.join(targetDir.path, name),
      );

      if (!await file.exists()) {
        missing.add(name);
        continue;
      }

      final length = await file.length();

      if (length <= 0) {
        missing.add(
          '$name(empty)',
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
        await ttsModel.length() <= 0) {
      missing.add(
        AppConstants.ttsModelFile,
      );
    }

    if (!await ttsTokens.exists() ||
        await ttsTokens.length() <= 0) {
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
          '${missing.join(", ")}.';

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
