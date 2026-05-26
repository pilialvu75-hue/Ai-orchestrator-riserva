import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ai_orchestrator/features/settings/model_management/model_runtime_manifest.dart';

enum ModelFileIntegrityStatus {
  unknown,
  present,
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
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(hours: 2),
                sendTimeout: const Duration(seconds: 30),
                headers: const <String, dynamic>{},
              ),
            );

  final Dio _dio;

  Future<List<ModelFileInspection>> inspectAll() async {
    final inspections = <ModelFileInspection>[];
    for (final spec in ModelRuntimeManifest.files) {
      inspections.add(await inspect(spec));
    }
    return inspections;
  }

  Future<ModelFileInspection> inspect(RuntimeModelFileSpec spec) async {
    final file = await _resolveFile(spec);
    final fullPath = file.path;
    try {
      final exists = await file.exists();
      if (!exists) {
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
        status: ModelFileIntegrityStatus.present,
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
    final destination = await _resolveFile(spec);
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

  bool _isInterruption(DioException error) {
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.unknown;
  }

  Future<File> _resolveFile(RuntimeModelFileSpec spec) async {
    final docDir = await getApplicationDocumentsDirectory();
    final fullPath = p.join(docDir.path, spec.relativeDirectory, spec.fileName);
    return File(fullPath);
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
