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
                headers: const <String, dynamic>{},
              ),
            ),
       _localAiRepository = localAiRepository;

  final Dio _dio;
  final LocalAiRepository _localAiRepository;
  final RuntimeModelPathResolver _pathResolver = const RuntimeModelPathResolver();

  Future<List<ModelFileInspection>> inspectAll() async {
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
    try {
      if (!resolution.exists) {
        return ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.missing,
          path: fullPath,
        );
      }
      final fileLength = await file.length();
      if (fileLength != spec.expectedBytes) {
        return ModelFileInspection(
          spec: spec,
          status: ModelFileIntegrityStatus.corrupted,
          path: fullPath,
          actualBytes: fileLength,
          message:
              'Dimensione errata: ${_formatBytes(fileLength)} / ${_formatBytes(spec.expectedBytes)}',
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

    final tempFile = File('${destination.path}.part');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    try {
      await _dio.download(
        spec.downloadUrl,
        tempFile.path,
        deleteOnError: true,
        options: Options(headers: const <String, dynamic>{}),
        onReceiveProgress: (received, total) {
          final denominator = total > 0 ? total : spec.expectedBytes;
          final progress = (received / denominator).clamp(0.0, 1.0).toDouble();
          onProgress(progress);
        },
      );

      final length = await tempFile.length();
      if (length != spec.expectedBytes) {
        await tempFile.delete();
        throw ModelDownloadFailureException(
          'File corrotto dopo download: ${_formatBytes(length)} / ${_formatBytes(spec.expectedBytes)}',
        );
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await tempFile.rename(destination.path);
      onProgress(1.0);
      return inspect(spec);
    } on DioException catch (error) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      if (_isInterruption(error)) {
        throw ModelDownloadInterruptedException(
          'Download interrotto - Clicca per riprovare',
        );
      }
      throw ModelDownloadFailureException(
        'Download fallito (${error.response?.statusCode ?? "N/A"}): ${error.message}',
      );
    } catch (error) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
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
}

class _ExportCopyJob {
  const _ExportCopyJob({
    required this.source,
    required this.destination,
  });

  final File source;
  final File destination;
}
