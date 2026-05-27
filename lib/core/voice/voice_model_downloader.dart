import 'dart:io';

import 'package:dio/dio.dart';

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
  }) : _dio = dio ??
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
      'voice assets now use app-private storage to avoid Android 11+ (API 30+) '
      'shared-storage restrictions and Android 13+ (API 33+) media permission limits',
    );
    return true;
  }

  Future<void> downloadModels({
    required Function(double) onProgress,
  }) async {
    final targetDir = await _ensureTargetDirectory();
    logEvent(_tag, '[DOWNLOAD_START] targetDir=${targetDir.path}');
    logEvent(
      _tag,
      '[URL_GENERATION] sttRepository=${AppConstants.sttZipformerEnRepository} '
      'baseUrl=${AppConstants.sttZipformerBaseUrl}',
    );

    // Emit storage forensics on every download session.
    await _logStorageForensics(targetDir);

    // Clean up any orphan .part temp files from previous interrupted sessions
    // before starting. A .part file is never a valid asset and must not be
    // mistaken for a complete file by validation logic.
    await _cleanOrphanPartFiles(targetDir);

    final specs = _voiceModelSpecs;

    final totalExpectedBytes = specs.fold<int>(
      0,
      (sum, spec) => sum + spec.expectedBytes,
    );
    var completedExpectedBytes = 0;
    onProgress(0.0);

    for (final spec in specs) {
      final destinationPath = '${targetDir.path}/${spec.fileName}';
      final destinationFile = File(destinationPath);
      logEvent(
        _tag,
        '[URL_RESOLVE] file=${spec.fileName} url=${spec.url}',
      );
      if (await _validateExistingFile(spec, destinationFile)) {
        logEvent(
          _tag,
          '[DOWNLOAD_SKIP] file=${spec.fileName} path=${destinationFile.path}',
        );
        completedExpectedBytes += spec.expectedBytes;
        onProgress(
          (completedExpectedBytes / totalExpectedBytes)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        continue;
      }

      final tempFile = File('$destinationPath.part');
      if (await tempFile.exists()) {
        logEvent(_tag, '[TEMP_CLEANUP] removing stale part: ${tempFile.path}');
        await tempFile.delete();
      }
      if (await destinationFile.exists()) {
        logEvent(
          _tag,
          '[DEST_CLEANUP] removing incomplete destination: ${destinationFile.path}',
        );
        await destinationFile.delete();
      }

      logEvent(
        _tag,
        '[DOWNLOAD_BEGIN] file=${spec.fileName} url=${spec.url} expectedBytes=${spec.expectedBytes}',
      );

      try {
        await _downloadFileAtomic(
          spec: spec,
          tempFile: tempFile,
          destinationFile: destinationFile,
          totalExpectedBytes: totalExpectedBytes,
          completedExpectedBytes: completedExpectedBytes,
          onProgress: onProgress,
        );
      } on DioException catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        if (_isInterruption(error)) {
          logEvent(
            _tag,
            '[LIFECYCLE_INTERRUPT] file=${spec.fileName} '
            'cause=${_classifyInterruptionCause(error)} '
            'dioType=${error.type} '
            'message=${error.message}',
          );
        }
        final statusCode = error.response?.statusCode;
        final message = statusCode == null
            ? 'Download del modello vocale fallito: ${spec.fileName}. ${error.message ?? "Errore di rete"}'
            : 'Download del modello vocale fallito: ${spec.fileName} (HTTP $statusCode).';
        logEvent(_tag, '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=$message');
        throw VoiceAssetException(message);
      } on VoiceAssetException catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        logEvent(
          _tag,
          '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=${error.message}',
        );
        rethrow;
      } catch (error) {
        await _cleanupTempFiles(tempFile, destinationFile);
        final message =
            'Download del modello vocale fallito: ${spec.fileName}. $error';
        logEvent(_tag, '[DOWNLOAD_FILE_FAIL] file=${spec.fileName} error=$message');
        throw VoiceAssetException(message);
      }

      completedExpectedBytes += spec.expectedBytes;
      onProgress(
        (completedExpectedBytes / totalExpectedBytes)
            .clamp(0.0, 1.0)
            .toDouble(),
      );
    }

    logEvent(
      _tag,
      '[EXTRACTION_COMPLETE] no extraction required for raw voice asset files',
    );
    await validateDownloadedAssets();
    logEvent(_tag, '[DOWNLOAD_COMPLETE] voice assets ready in ${targetDir.path}');
    onProgress(1.0);
  }

  Future<void> validateDownloadedAssets() async {
    logEvent(_tag, '[ASSET_VALIDATION_BEGIN] checking required voice files');
    final missingOrInvalid = <String>[];
    String? resolvedDirectoryPath;

    // Remove any orphan .part files before validating so that a stale partial
    // download is never mistakenly counted as a valid asset.
    try {
      final targetDir = await _pathResolver.privateModelsDirectory();
      if (await targetDir.exists()) {
        await _cleanOrphanPartFiles(targetDir);
      }
    } catch (_) {}

    for (final spec in _voiceModelSpecs) {
      final resolution = await _pathResolver.resolveForRead(
        fileName: spec.fileName,
      );
      final file = await _selectValidDownloadedFile(spec, resolution);
      resolvedDirectoryPath ??= file?.parent.path ?? resolution.privateFile.parent.path;

      final parentExists = file != null && await file.parent.exists();
      if (!parentExists || file == null) {
        logEvent(
          _tag,
          '[ASSET_MISSING] file=${spec.fileName} expectedPrivate=${resolution.privateFile.path} expectedPublic=${resolution.publicFile.path}',
        );
        missingOrInvalid.add(spec.fileName);
      }
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
      '[ASSET_VALIDATION_COMPLETE] all voice assets available dir=${resolvedDirectoryPath ?? "unknown"}',
    );
  }

  /// Downloads [spec] atomically: streams to a `.part` temp file, explicitly
  /// flushes and closes the sink, validates byte count against the HTTP
  /// content-length header (when available) and against the 85 % minimum
  /// threshold, then renames the temp file to the final path only after all
  /// checks pass.  Progress is reported as an aggregate over all specs.
  Future<void> _downloadFileAtomic({
    required _VoiceModelDownloadSpec spec,
    required File tempFile,
    required File destinationFile,
    required int totalExpectedBytes,
    required int completedExpectedBytes,
    required void Function(double) onProgress,
  }) async {
    // Stream-based GET so we control the IOSink and can call flush() explicitly.
    final response = await _dio.get<ResponseBody>(
      spec.url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: const <String, dynamic>{},
      ),
    );

    final contentLengthHeader = response.headers.value(HttpHeaders.contentLengthHeader);
    final serverContentLength = int.tryParse(contentLengthHeader ?? '') ?? -1;
    logEvent(
      _tag,
      '[CONTENT_LENGTH] file=${spec.fileName} '
      'content-length=$serverContentLength expectedBytes=${spec.expectedBytes}',
    );

    final sink = tempFile.openWrite();
    int bytesWritten = 0;

    try {
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        bytesWritten += chunk.length;
        // Report incremental progress.
        final denominator =
            serverContentLength > 0 ? serverContentLength : spec.expectedBytes;
        final fileProgress = (bytesWritten / denominator).clamp(0.0, 1.0);
        final aggregate =
            (completedExpectedBytes + fileProgress * spec.expectedBytes) /
                totalExpectedBytes;
        onProgress(aggregate.clamp(0.0, 1.0).toDouble());
      }

      logEvent(
        _tag,
        '[BYTES_WRITTEN] file=${spec.fileName} bytesWritten=$bytesWritten',
      );

      // Flush the IOSink to push any buffered data through to the OS page
      // cache, then close to trigger the underlying file descriptor close.
      // On Android, closing an IOSink backed by a RandomAccessFile calls
      // fsync internally, ensuring writes survive a subsequent app kill.
      final flushStopwatch = Stopwatch()..start();
      await sink.flush();
      flushStopwatch.stop();
      logEvent(_tag, '[FILE_FLUSHED] file=${spec.fileName}');
      logEvent(
        _tag,
        '[FORENSIC_TIMING] file=${spec.fileName} phase=flush durationMs=${flushStopwatch.elapsedMilliseconds}',
      );
      final closeStopwatch = Stopwatch()..start();
      await sink.close();
      closeStopwatch.stop();
      logEvent(_tag, '[STREAM_CLOSED] file=${spec.fileName}');
      logEvent(
        _tag,
        '[FORENSIC_TIMING] file=${spec.fileName} phase=close durationMs=${closeStopwatch.elapsedMilliseconds}',
      );
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {}
      logEvent(
        _tag,
        '[STREAM_ERROR] file=${spec.fileName} error=$error',
      );
      rethrow;
    }

    logEvent(
      _tag,
      '[DOWNLOAD_STREAM_COMPLETE] file=${spec.fileName} '
      'bytesWritten=$bytesWritten '
      'serverContentLength=$serverContentLength '
      'expectedBytes=${spec.expectedBytes}',
    );

    // Strict content-length check: if the server advertised a size and we
    // received fewer bytes, the file is truncated — reject it immediately.
    if (serverContentLength > 0 && bytesWritten < serverContentLength) {
      throw VoiceAssetException(
        'Download truncated: ${spec.fileName} '
        '($bytesWritten byte ricevuti, server ha dichiarato $serverContentLength).',
      );
    }

    // Minimum-size guard: ensures we don't rename a fragment file.
    final minBytes = (spec.expectedBytes * 0.85).toInt();
    if (bytesWritten <= 0) {
      throw VoiceAssetException(
        'File vocale vuoto dopo il download: ${spec.fileName}.',
      );
    }
    if (bytesWritten < minBytes) {
      throw VoiceAssetException(
        'File vocale incompleto o corrotto: ${spec.fileName} '
        '($bytesWritten byte ricevuti, attesi almeno $minBytes).',
      );
    }

    // Atomic rename: only expose the final path when the temp file is fully
    // validated.
    logEvent(
      _tag,
      '[TEMP_RENAME_BEGIN] temp=${tempFile.path} -> dest=${destinationFile.path}',
    );
    try {
      final renameStopwatch = Stopwatch()..start();
      await tempFile.rename(destinationFile.path);
      renameStopwatch.stop();
      logEvent(
        _tag,
        '[FORENSIC_TIMING] file=${spec.fileName} phase=rename durationMs=${renameStopwatch.elapsedMilliseconds}',
      );
    } catch (renameError) {
      logEvent(
        _tag,
        '[TEMP_RENAME_FAIL] file=${spec.fileName} error=$renameError',
      );
      rethrow;
    }
    logEvent(_tag, '[TEMP_RENAME_OK] file=${spec.fileName}');

    // Post-rename integrity check: verify the final file is readable and
    // meets the minimum size threshold before reporting success.
    final validationStopwatch = Stopwatch()..start();
    await _validateFinalFile(spec, destinationFile);
    validationStopwatch.stop();
    logEvent(
      _tag,
      '[FORENSIC_TIMING] file=${spec.fileName} phase=validation durationMs=${validationStopwatch.elapsedMilliseconds}',
    );
    logEvent(
      _tag,
      '[DOWNLOAD_FINALIZED] file=${spec.fileName} '
      'bytes=$bytesWritten path=${destinationFile.path}',
    );
  }

  /// Logs available disk space for forensic diagnostics.
  Future<void> _logStorageForensics(Directory targetDir) async {
    try {
      logEvent(
        _tag,
        '[STORAGE_PATH] targetDir=${targetDir.path}',
      );
      if (Platform.isAndroid || Platform.isLinux) {
        final stat = await FileStat.stat(targetDir.path);
        logEvent(_tag, '[STORAGE_STAT] type=${stat.type} modified=${stat.modified}');
      }
    } catch (error) {
      logEvent(_tag, '[STORAGE_FORENSICS_WARN] unable to query storage: $error');
    }
  }

  /// Deletes all orphan `.part` temp files in [targetDir].
  /// Orphan `.part` files are left over from interrupted downloads and must
  /// never be treated as valid assets.
  Future<void> _cleanOrphanPartFiles(Directory targetDir) async {
    try {
      await for (final entity in targetDir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.part')) continue;
        logEvent(
          _tag,
          '[ORPHAN_TEMP_CLEANUP] deleting stale part file: ${entity.path}',
        );
        try {
          await entity.delete();
        } catch (deleteError) {
          logEvent(
            _tag,
            '[ORPHAN_TEMP_CLEANUP_WARN] failed to delete ${entity.path}: $deleteError',
          );
        }
      }
    } catch (error) {
      logEvent(_tag, '[ORPHAN_TEMP_CLEANUP_WARN] list error: $error');
    }
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
      // A .part file is never a valid asset regardless of size.
      if (file.path.endsWith('.part')) return false;
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      // Validazione tollerante: accetta il file se copre almeno l'85% della dimensione attesa.
      // Questo evita blocchi dovuti a variazioni minime sui server remoti o compressioni di rete.
      final minBytes = (spec.expectedBytes * 0.85).toInt();
      return length >= minBytes;
    } catch (_) {
      return false;
    }
  }

  /// Post-rename integrity check used exclusively on the final destination
  /// file (after the atomic rename).  Requires existence, non-zero length,
  /// and the 85% minimum-size threshold.
  Future<void> _validateFinalFile(
    _VoiceModelDownloadSpec spec,
    File file,
  ) async {
    if (!await file.exists()) {
      throw VoiceAssetException(
        'File vocale non trovato dopo il rename: ${spec.fileName}.',
      );
    }

    final length = await file.length();
    if (length <= 0) {
      throw VoiceAssetException(
        'File vocale vuoto dopo il rename: ${spec.fileName}.',
      );
    }

    final minBytes = (spec.expectedBytes * 0.85).toInt();
    if (length < minBytes) {
      throw VoiceAssetException(
        'File vocale incompleto dopo il rename: ${spec.fileName} '
        '($length byte rilevati, attesi almeno $minBytes).',
      );
    }
  }

  Future<File?> _selectValidDownloadedFile(
    _VoiceModelDownloadSpec spec,
    RuntimeModelResolution resolution,
  ) async {
    if (await _validateExistingFile(spec, resolution.privateFile)) {
      return resolution.privateFile;
    }
    if (await _validateExistingFile(spec, resolution.publicFile)) {
      return resolution.publicFile;
    }
    if (await _validateExistingFile(spec, resolution.file)) {
      return resolution.file;
    }
    return null;
  }

  Future<void> _cleanupTempFiles(File tempFile, File destinationFile) async {
    if (await tempFile.exists()) {
      logEvent(
        _tag,
        '[CLEANUP_TEMP] deleting temp file: ${tempFile.path}',
      );
      try {
        await tempFile.delete();
      } catch (error) {
        logEvent(_tag, '[CLEANUP_TEMP_WARN] failed to delete ${tempFile.path}: $error');
      }

      bool _isInterruption(DioException error) {
        return error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            error.type == DioExceptionType.cancel ||
            error.type == DioExceptionType.unknown;
      }

      String _classifyInterruptionCause(DioException error) {
        if (error.type == DioExceptionType.cancel) {
          return 'cancelled';
        }
        if (error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout) {
          return 'timeout';
        }
        if (error.type == DioExceptionType.connectionError) {
          return 'connectivity_loss';
        }
        return 'unknown_interrupt';
      }
    }
    if (await destinationFile.exists()) {
      logEvent(
        _tag,
        '[CLEANUP_DEST] deleting partial destination: ${destinationFile.path}',
      );
      try {
        await destinationFile.delete();
      } catch (error) {
        logEvent(
          _tag,
          '[CLEANUP_DEST_WARN] failed to delete ${destinationFile.path}: $error',
        );
      }
    }
  }

  List<_VoiceModelDownloadSpec> get _voiceModelSpecs => const <_VoiceModelDownloadSpec>[
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
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsModelFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/vits-tts-it-paola.onnx',
          expectedBytes: 120 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsLexiconFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt',
          expectedBytes: 1 * 1024 * 1024,
        ),
        _VoiceModelDownloadSpec(
          fileName: AppConstants.ttsTokensFile,
          url: 'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt',
          expectedBytes: 85 * 1024,
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
