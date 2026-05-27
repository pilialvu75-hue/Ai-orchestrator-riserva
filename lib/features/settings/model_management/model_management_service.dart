import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_runtime_manifest.dart';

enum ModelFileIntegrityStatus {
  unknown,
  presentPublicStorage,
  presentInternalStorage,
  // File is present but below the minimum acceptable size threshold (< 85% of
  // expected).  This indicates a previously interrupted or truncated download.
  incomplete,
  missing,
  corrupted,
  interrupted,
  failed,
}

class ModelFileInspection {
  const ModelFileInspection({
    required this.spec,
    required this.status,
    required this.path,
    this.actualBytes,
    this.message,
  });

  final RuntimeModelFileSpec spec;
  final ModelFileIntegrityStatus status;
  final String path;
  final int? actualBytes;
  final String? message;
}

class ModelDownloadInterruptedException implements Exception {
  const ModelDownloadInterruptedException(this.message);

  final String message;
}

class ModelDownloadFailureException implements Exception {
  const ModelDownloadFailureException(this.message);

  final String message;
}

class ModelManagementService {
  ModelManagementService({
    Dio? dio,
    required LocalAiRepository localAiRepository,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 2),
                sendTimeout: const Duration(seconds: 30),
                followRedirects: true,
                maxRedirects: 10,
                headers: const <String, dynamic>{},
              ),
            ),
       _localAiRepository = localAiRepository;

  final Dio _dio;
  final LocalAiRepository _localAiRepository;
  final RuntimeModelPathResolver _pathResolver = const RuntimeModelPathResolver();

  // Minimum acceptable fraction of expectedBytes for a file to be considered
  // present and usable.  Files below this threshold are treated as incomplete
  // (interrupted download).  This mirrors the same constant used by
  // VoiceModelDownloader so both pipelines apply identical acceptance criteria.
  static const double _minAcceptableFraction = 0.85;

  Future<List<ModelFileInspection>> inspectAll() async {
    // Remove orphan .part files before scanning so that a stale partial
    // download is never mistakenly reported as a valid present file.
    await _cleanOrphanPartFiles();
    final inspections = <ModelFileInspection>[];
    for (final spec in ModelRuntimeManifest.files) {
      inspections.add(await inspect(spec));
    }
    return inspections;
  }

  Future<ModelFileInspection> inspect(RuntimeModelFileSpec spec) async {
    final resolution = await _resolveFile(spec);
    final file = resolution.file;
    final fullPath = file.path;
    // A .part file is never a valid asset; treat it as missing.
    if (fullPath.endsWith('.part')) {
      return ModelFileInspection(
        spec: spec,
        status: ModelFileIntegrityStatus.missing,
        path: fullPath,
        message: 'Temp (.part) file detected — not a valid asset',
      );
    }
    try {
      if (!resolution.exists) {
        return ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.missing,
          path: fullPath,
        );
      }
      final fileLength = await file.length();
      if (fileLength <= 0) {
        return ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.missing,
          path: fullPath,
          actualBytes: fileLength,
          message: 'File vuoto (0 byte rilevati)',
        );
      }
      final minBytes = (spec.expectedBytes * _minAcceptableFraction).toInt();
      if (fileLength < minBytes) {
        return ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.incomplete,
          path: fullPath,
          actualBytes: fileLength,
          message:
              'Download incompleto: ${_formatBytes(fileLength)} rilevati, '
              'attesi almeno ${_formatBytes(minBytes)} '
              '(${_formatBytes(spec.expectedBytes)} stimati)',
        );
      }
      return ModelFileInspection(
        spec: spec,
        status: resolution.location == RuntimeModelStorageLocation.publicDownload
            ? ModelFileIntegrityStatus.presentPublicStorage
            : ModelFileIntegrityStatus.presentInternalStorage,
        path: fullPath,
        actualBytes: fileLength,
      );
    } catch (error) {
      return ModelFileInspection(
        spec: spec,
        status: ModelFileIntegrityStatus.failed,
        path: fullPath,
        message: 'Errore verifica: $error',
      );
    }
  }

  Future<ModelFileInspection> forceDownload(
    RuntimeModelFileSpec spec, {
    required void Function(double progress) onProgress,
  }) async {
    final destination = await _resolvePrivateFile(spec);
    final destinationDir = destination.parent;
    if (!await destinationDir.exists()) {
      await destinationDir.create(recursive: true);
    }

    // Emit storage forensics before each download.
    _logStorageForensics(destinationDir);

    // Remove any stale .part file from a previous interrupted session.
    final tempFile = File('${destination.path}.part');
    if (await tempFile.exists()) {
      _log('[FORCE_DL_TEMP_CLEANUP] removing stale temp file: ${tempFile.path}');
      await _safeDeleteFile(tempFile, '[FORCE_DL_TEMP_CLEANUP]');
    }

    _log(
      '[DOWNLOAD_BEGIN] file=${spec.fileName} '
      'url=${spec.downloadUrl} '
      'expectedBytes=${spec.expectedBytes} '
      'dest=${destination.path}',
    );

    try {
      // Stream-based GET for explicit flush control (see VoiceModelDownloader).
      final response = await _dio.get<ResponseBody>(
        spec.downloadUrl,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: const <String, dynamic>{},
        ),
      );

      final contentLengthHeader =
          response.headers.value(HttpHeaders.contentLengthHeader);
      final serverContentLength =
          int.tryParse(contentLengthHeader ?? '') ?? -1;
      _log(
        '[CONTENT_LENGTH] file=${spec.fileName} '
        'content-length=$serverContentLength expectedBytes=${spec.expectedBytes}',
      );

      final sink = tempFile.openWrite();
      int bytesWritten = 0;

      try {
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          bytesWritten += chunk.length;
          final denominator = serverContentLength > 0
              ? serverContentLength
              : spec.expectedBytes;
          final progress =
              (bytesWritten / denominator).clamp(0.0, 1.0).toDouble();
          onProgress(progress);
        }

        _log('[BYTES_WRITTEN] file=${spec.fileName} bytesWritten=$bytesWritten');

        await sink.flush();
        _log('[FILE_FLUSHED] file=${spec.fileName}');
        await sink.close();
        _log('[STREAM_CLOSED] file=${spec.fileName}');
      } catch (streamError) {
        try {
          await sink.close();
        } catch (_) {}
        _log('[STREAM_ERROR] file=${spec.fileName} error=$streamError');
        rethrow;
      }

      _log(
        '[FORCE_DL_DOWNLOADED] file=${spec.fileName} '
        'bytesWritten=$bytesWritten '
        'serverContentLength=$serverContentLength '
        'expectedBytes=${spec.expectedBytes}',
      );

      // Strict content-length check.
      if (serverContentLength > 0 && bytesWritten < serverContentLength) {
        await _safeDeleteFile(tempFile, '[FORCE_DL_REJECT_TRUNCATED]');
        throw ModelDownloadFailureException(
          'Download troncato: ${spec.fileName} '
          '($bytesWritten byte ricevuti, server ha dichiarato $serverContentLength)',
        );
      }

      final minBytes = (spec.expectedBytes * _minAcceptableFraction).toInt();
      if (bytesWritten <= 0) {
        await _safeDeleteFile(tempFile, '[FORCE_DL_REJECT_EMPTY]');
        throw ModelDownloadFailureException(
          'File vuoto dopo download: ${spec.fileName}',
        );
      }
      if (bytesWritten < minBytes) {
        await _safeDeleteFile(tempFile, '[FORCE_DL_REJECT_INCOMPLETE]');
        throw ModelDownloadFailureException(
          'Download incompleto: ${_formatBytes(bytesWritten)} ricevuti, '
          'attesi almeno ${_formatBytes(minBytes)} '
          '(${_formatBytes(spec.expectedBytes)} stimati) — ${spec.fileName}',
        );
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      _log(
        '[TEMP_RENAME_BEGIN] temp=${tempFile.path} -> dest=${destination.path}',
      );
      try {
        await tempFile.rename(destination.path);
      } catch (renameError) {
        _log(
          '[TEMP_RENAME_FAIL] file=${spec.fileName} error=$renameError',
        );
        rethrow;
      }
      _log('[TEMP_RENAME_OK] file=${spec.fileName}');

      onProgress(1.0);
      final inspection = await inspect(spec);
      _log(
        '[DOWNLOAD_FINALIZED] file=${spec.fileName} '
        'status=${inspection.status} '
        'actualBytes=${inspection.actualBytes ?? "unknown"}',
      );
      return inspection;
    } on DioException catch (error) {
      await _safeDeleteFile(tempFile, '[FORCE_DL_DIO_ERROR_CLEANUP]');
      _log(
        '[FORCE_DL_FAIL] file=${spec.fileName} '
        'dioType=${error.type} '
        'statusCode=${error.response?.statusCode ?? "N/A"} '
        'message=${error.message}',
      );
      if (_isInterruption(error)) {
        throw ModelDownloadInterruptedException(
          'Download interrotto - Clicca per riprovare',
        );
      }
      throw ModelDownloadFailureException(
        'Download fallito (${error.response?.statusCode ?? "N/A"}): ${error.message}',
      );
    } catch (error) {
      await _safeDeleteFile(tempFile, '[FORCE_DL_ERROR_CLEANUP]');
      _log('[FORCE_DL_FAIL] file=${spec.fileName} error=$error');
      if (error is ModelDownloadInterruptedException ||
          error is ModelDownloadFailureException) {
        rethrow;
      }
      throw ModelDownloadFailureException('Errore download: $error');
    }
  }

  Future<void> exportAllRuntimeModels({
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const ModelDownloadFailureException(
        'Esportazione disponibile solo su Android.',
      );
    }

    final hasPermission = await _checkAndRequestStoragePermissions();
    if (!hasPermission) {
      throw const ModelDownloadFailureException(
        'Permessi storage negati. Abilita l’accesso ai file e riprova.',
      );
    }

    final publicDir = await _pathResolver.ensurePublicModelsDirectory();
    final copyJobs = <_ExportCopyJob>[];
    final seenDestinations = <String>{};

    for (final spec in ModelRuntimeManifest.files) {
      final source = await _resolvePrivateFile(spec);
      if (!await source.exists()) continue;
      final destination = File(p.join(publicDir.path, spec.fileName));
      if (!seenDestinations.add(destination.path)) continue;
      copyJobs.add(
        _ExportCopyJob(
          source: source,
          destination: destination,
        ),
      );
    }

    final llmSource = await _resolveLlmFileToExport();
    if (llmSource != null) {
      final fileName = p.basename(llmSource.path);
      final destination = File(p.join(publicDir.path, fileName));
      if (seenDestinations.add(destination.path)) {
        copyJobs.add(
          _ExportCopyJob(
            source: llmSource,
            destination: destination,
          ),
        );
      }
    }

    if (copyJobs.isEmpty) {
      onProgress(1.0);
      return;
    }

    onProgress(0.0);
    for (var index = 0; index < copyJobs.length; index++) {
      final job = copyJobs[index];
      await _copyFileWithProgress(
        source: job.source,
        destination: job.destination,
        onProgress: (fileProgress) {
          final aggregate = (index + fileProgress) / copyJobs.length;
          onProgress(aggregate.clamp(0.0, 1.0).toDouble());
        },
      );
      onProgress(((index + 1) / copyJobs.length).clamp(0.0, 1.0).toDouble());
    }
  }

  bool _isInterruption(DioException error) {
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.unknown;
  }

  Future<RuntimeModelResolution> _resolveFile(RuntimeModelFileSpec spec) {
    return _pathResolver.resolveForRead(
      fileName: spec.fileName,
      privateRelativeDirectory: spec.relativeDirectory,
    );
  }

  Future<File> _resolvePrivateFile(RuntimeModelFileSpec spec) {
    return _pathResolver.privateFileByName(
      spec.fileName,
      relativeDirectory: spec.relativeDirectory,
    );
  }

  Future<bool> _checkAndRequestStoragePermissions() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted) {
      return true;
    }
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<File?> _resolveLlmFileToExport() async {
    final selected = await _localAiRepository.getSelectedModel();
    String? selectedPath;
    selected.fold(
      (_) {},
      (model) {
        selectedPath = model?.localPath;
      },
    );

    if (selectedPath != null && selectedPath!.trim().isNotEmpty) {
      final selectedFileName = p.basename(selectedPath!.trim());
      final resolution = await _pathResolver.resolveForRead(
        fileName: selectedFileName,
        privateAbsolutePathHint: selectedPath!.trim(),
      );
      if (resolution.exists) {
        return resolution.file;
      }
    }

    final privateDir = await _pathResolver.privateModelsDirectory();
    if (!await privateDir.exists()) {
      return null;
    }
    try {
      await for (final entity in privateDir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.gguf')) continue;
        if (await entity.exists()) return entity;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _copyFileWithProgress({
    required File source,
    required File destination,
    required void Function(double progress) onProgress,
  }) async {
    if (source.path == destination.path) {
      onProgress(1.0);
      return;
    }
    final parent = destination.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final totalBytes = await source.length();
    if (totalBytes <= 0) {
      await source.copy(destination.path);
      onProgress(1.0);
      return;
    }
    final sink = destination.openWrite();
    var copiedBytes = 0;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        copiedBytes += chunk.length;
        onProgress((copiedBytes / totalBytes).clamp(0.0, 1.0).toDouble());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress(1.0);
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0B';
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)}MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)}KB';
    }
    return '${bytes}B';
  }

  // Deletes a file if it exists, logging the action with the provided tag.
  // Deletion failures are logged but not rethrown: a failed cleanup is not
  // a fatal error (the partial file may be re-deleted on next attempt), and
  // the original download exception must propagate unmodified to the caller.
  Future<void> _safeDeleteFile(File file, String logTag) async {
    if (await file.exists()) {
      _log('$logTag path=${file.path}');
      try {
        await file.delete();
      } catch (deleteError) {
        _log('$logTag DELETE_WARN unable to delete file: $deleteError');
      }
    }
  }

  /// Deletes all orphan `.part` temp files in the private models directory.
  /// Orphan `.part` files are left over from interrupted downloads and must
  /// never be treated as valid assets.
  Future<void> _cleanOrphanPartFiles() async {
    try {
      final privateDir = await _pathResolver.privateModelsDirectory();
      if (!await privateDir.exists()) return;
      await for (final entity in privateDir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.part')) continue;
        _log('[ORPHAN_TEMP_CLEANUP] deleting stale part file: ${entity.path}');
        await _safeDeleteFile(entity, '[ORPHAN_TEMP_CLEANUP]');
      }
    } catch (error) {
      _log('[ORPHAN_TEMP_CLEANUP_WARN] list error: $error');
    }
  }

  /// Emits storage forensic diagnostics for the given directory.
  void _logStorageForensics(Directory dir) {
    _log('[STORAGE_PATH] dir=${dir.path}');
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        _log('[STORAGE_PLATFORM] platform=${Platform.operatingSystem}');
      }
    } catch (_) {}
  }

  // ignore: avoid_print
  static void _log(String message) => print('[MODEL_MGMT] $message');
}

class _ExportCopyJob {
  const _ExportCopyJob({
    required this.source,
    required this.destination,
  });

  final File source;
  final File destination;
}
