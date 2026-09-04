import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/bundled_model_registry_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';

/// Magic bytes that every valid GGUF file starts with: ASCII "GGUF".
const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

const String _filePickerPlatformExceptionCode = 'FilePicker';

class _ModelFileValidationResult {
  const _ModelFileValidationResult(this.status, {this.message});

  final ModelValidationStatus status;
  final String? message;
}

/// Low-level service that handles model file I/O and downloads.
///
/// Downloading is resumable:
///
///   .part missing
///        ↓
///   normal HTTP download
///
///   .part exists
///        ↓
///   HTTP Range: bytes=<existing>-
///        ↓
///   206 → append
///   200 → server ignored Range → restart safely from zero
///
/// A failed network transfer never promotes the .part file to the final
/// GGUF path. The partial file is deliberately preserved so that the next
/// attempt can continue from the already downloaded bytes.
///
/// The same service also supports exporting downloaded GGUF models to the
/// public runtime-model directory used by the existing Voice/Model Management
/// infrastructure.
class ModelDownloadService {
  ModelDownloadService({
    Dio? dio,
    FilePicker? filePicker,
    BundledModelRegistryService? bundledModelRegistryService,
  })  : _dio = dio ?? _buildDownloadDio(),
        _filePicker = filePicker ?? FilePicker.platform,
        _bundledModelRegistryService =
            bundledModelRegistryService ??
                const BundledModelRegistryService();

  /// Builds a Dio instance explicitly configured for public unauthenticated
  /// model downloads.
  static Dio _buildDownloadDio() {
    return Dio(
      BaseOptions(
        headers: const <String, dynamic>{},
        followRedirects: true,
        maxRedirects: 10,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: AppConstants.modelDownloadTimeout,
        sendTimeout: const Duration(seconds: 30),
      ),
    );
  }

  final Dio _dio;
  final FilePicker _filePicker;
  final BundledModelRegistryService _bundledModelRegistryService;

  final RuntimeModelPathResolver _pathResolver =
      const RuntimeModelPathResolver();

  final Map<String, CancelToken> _cancelTokens = {};

  static const Uuid _uuid = Uuid();

  static const MethodChannel _androidChannel =
      MethodChannel('com.aiorchestrator/android_intents');

  static const int _maxDownloadAttempts = 3;

  // ── Model list helpers ─────────────────────────────────────────────────────

  /// Builds the list of [AiModel] objects, checking local storage for each one.
  ///
  /// Built-in models are loaded from the shared manifest through
  /// [BundledModelRegistryService]. Custom and imported models are merged into
  /// the same list.
  Future<List<AiModel>> getAvailableModels() async {
    final modelsDir = await _modelsDirectory();

    final catalog = await _bundledModelRegistryService.loadCatalog();

    final builtIn = await Future.wait(
      catalog.map(
        (m) async {
          final fileName = m['fileName'] as String;
          final file = File('${modelsDir.path}/$fileName');

          final resolution = await _pathResolver.resolveForRead(
            fileName: fileName,
            privateAbsolutePathHint: file.path,
          );

          final downloaded = resolution.exists;
          final effectiveFile = resolution.file;

          final ModelValidationStatus status;

          if (downloaded) {
            status = await _validateModelFile(effectiveFile);
          } else {
            status = ModelValidationStatus.notDownloaded;
          }

          return AiModel(
            id: m['id'] as String,
            displayName: m['displayName'] as String,
            fileName: fileName,
            downloadUrl: m['downloadUrl'] as String,
            version: m['version'] as String,
            sizeBytes: m['sizeBytes'] as int,
            sizeCategory: m['sizeCategory'] as String? ??
                _inferSizeCategory(
                  fileName: fileName,
                  sizeBytes: m['sizeBytes'] as int,
                  runtimeModelId: m['id'] as String,
                ),
            description: m['description'] as String,
            isDownloaded: downloaded,
            localPath: downloaded ? effectiveFile.path : null,
            platformTarget: m['platformTarget'] as String?,
            validationStatus: status,
          );
        },
      ),
    );

    final custom = await loadCustomModelEntries();
    final imported = await loadImportedModelEntries();

    final verifiedCustom = await Future.wait(
      custom.map(_refreshStoredModel),
    );

    final verifiedImported = await Future.wait(
      imported.map(_refreshStoredModel),
    );

    return <AiModel>[
      ...builtIn,
      ...verifiedCustom,
      ...verifiedImported,
    ];
  }

  // ── Download ───────────────────────────────────────────────────────────────

  /// Downloads [model] using resumable `.part` storage.
  ///
  /// The partial file survives network failures, process interruption and
  /// cancellation. A final GGUF is published only after validation succeeds.
  Future<AiModel> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.tryParse(model.downloadUrl);

    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw DownloadException(
        'Invalid download URL for ${model.id}: "${model.downloadUrl}"',
      );
    }

    final modelsDir = await _modelsDirectory();
    final filePath = '${modelsDir.path}/${model.fileName}';

    return _downloadResumable(
      modelId: model.id,
      url: model.downloadUrl,
      filePath: filePath,
      expectedBytes: model.sizeBytes,
      onProgress: onProgress,
    ).then(
      (result) {
        return model.copyWith(
          isDownloaded: true,
          localPath: result.path,
          validationStatus: result.status,
          sizeCategory: _inferSizeCategory(
            fileName: model.fileName,
            sizeBytes: result.sizeBytes,
            runtimeModelId: model.runtimeModelId ?? model.id,
          ),
        );
      },
    );
  }

  /// Cancels an in-progress download.
  ///
  /// The `.part` file is intentionally preserved so that the next attempt
  /// can resume from the existing byte count.
  void cancelDownload(String modelId) {
    _cancelTokens[modelId]?.cancel('User cancelled');
    _cancelTokens.remove(modelId);
  }

  // ── Custom URL download ────────────────────────────────────────────────────

  Future<AiModel> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.tryParse(url);

    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw DownloadException(
        'Invalid download URL for $modelId: "$url"',
      );
    }

    final modelsDir = await _modelsDirectory();
    final filePath = '${modelsDir.path}/$fileName';

    final result = await _downloadResumable(
      modelId: modelId,
      url: url,
      filePath: filePath,
      expectedBytes: 0,
      onProgress: onProgress,
    );

    final model = AiModel(
      id: modelId,
      displayName: displayName,
      fileName: fileName,
      downloadUrl: url,
      version: '1.0.0',
      sizeBytes: result.sizeBytes,
      description: 'Custom model from $url',
      isDownloaded: true,
      localPath: result.path,
      platformTarget: 'all',
      validationStatus: result.status,
      sizeCategory: _inferSizeCategory(
        fileName: fileName,
        sizeBytes: result.sizeBytes,
        runtimeModelId: modelId,
      ),
      source: 'custom_url',
    );

    await saveCustomModelEntry(model);

    return model;
  }

  // ── Resumable transfer implementation ─────────────────────────────────────

  Future<_DownloadResult> _downloadResumable({
    required String modelId,
    required String url,
    required String filePath,
    required int expectedBytes,
    void Function(double progress)? onProgress,
  }) async {
    final finalFile = File(filePath);
    final partFile = File('$filePath.part');

    final cancelToken = CancelToken();
    _cancelTokens[modelId] = cancelToken;

    try {
      for (var attempt = 1; attempt <= _maxDownloadAttempts; attempt++) {
        try {
          if (await finalFile.exists()) {
            final existingLength = await finalFile.length();

            if (existingLength > 0) {
              final validation = await _validateModelFileDetailed(
                finalFile,
                treatMissingAsMissing: false,
              );

              if (validation.status ==
                  ModelValidationStatus.validatedOk) {
                return _DownloadResult(
                  path: finalFile.path,
                  sizeBytes: existingLength,
                  status: validation.status,
                );
              }
            }
          }

          var existingBytes = 0;

          if (await partFile.exists()) {
            existingBytes = await partFile.length();

            if (existingBytes > 0) {
              final partialValidation = await _validateModelFileDetailed(
                partFile,
                treatMissingAsMissing: false,
              );

              if (partialValidation.status ==
                      ModelValidationStatus.validatedOk &&
                  (expectedBytes <= 0 ||
                      existingBytes >=
                          (expectedBytes * 0.70).toInt())) {
                if (await finalFile.exists()) {
                  await finalFile.delete();
                }

                await partFile.rename(finalFile.path);

                final finalLength = await finalFile.length();

                onProgress?.call(1.0);

                return _DownloadResult(
                  path: finalFile.path,
                  sizeBytes: finalLength,
                  status: partialValidation.status,
                );
              }
            }
          }

          if (existingBytes > 0) {
            onProgress?.call(
              _initialProgress(
                existingBytes: existingBytes,
                expectedBytes: expectedBytes,
              ),
            );
          }

          final headers = <String, dynamic>{
            'Accept': '*/*',
          };

          if (existingBytes > 0) {
            headers['Range'] = 'bytes=$existingBytes-';
          }

          final response = await _dio.get<ResponseBody>(
            url,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: headers,
              followRedirects: true,
              maxRedirects: 10,
              validateStatus: (status) {
                return status != null &&
                    ((status >= 200 && status < 300) || status == 416);
              },
            ),
          );

          final statusCode = response.statusCode ?? 0;

          // A 416 can mean the .part already contains the complete object.
          // Validate it before promoting it.
          if (statusCode == 416 && existingBytes > 0) {
            final validation = await _validateModelFileDetailed(
              partFile,
              treatMissingAsMissing: false,
            );

            if (validation.status ==
                ModelValidationStatus.validatedOk) {
              if (await finalFile.exists()) {
                await finalFile.delete();
              }

              await partFile.rename(finalFile.path);

              final finalLength = await finalFile.length();

              onProgress?.call(1.0);

              return _DownloadResult(
                path: finalFile.path,
                sizeBytes: finalLength,
                status: validation.status,
              );
            }

            throw DownloadException(
              'Server rejected resume for $modelId (HTTP 416) '
              'and the partial file is not a valid GGUF.',
            );
          }

          if (response.data == null) {
            throw DownloadException(
              'Empty download response for $modelId.',
            );
          }

          final contentRange =
              response.headers.value('content-range');

          final contentLengthHeader =
              response.headers.value('content-length');

          final contentLength =
              int.tryParse(contentLengthHeader ?? '');

          final rangeStart = _parseRangeStart(contentRange);
          final rangeTotal = _parseRangeTotal(contentRange);

          var append = existingBytes > 0 && statusCode == 206;

          // Some servers ignore Range and answer 200. Never append a full
          // object to an existing partial file in that situation.
          if (existingBytes > 0 && statusCode == 200) {
            append = false;
            existingBytes = 0;
          }

          // If the server returned 206 but starts at a different offset,
          // refuse to append potentially duplicated/corrupt bytes.
          if (append &&
              rangeStart != null &&
              rangeStart != existingBytes) {
            append = false;
            existingBytes = 0;
          }

          final totalBytes = rangeTotal ??
              (append && contentLength != null
                  ? existingBytes + contentLength
                  : contentLength ?? expectedBytes);

          final sink = partFile.openWrite(
            mode: append ? FileMode.append : FileMode.write,
          );

          var receivedBytes = 0;

          try {
            await for (final chunk in response.data!.stream) {
              if (cancelToken.isCancelled) {
                throw DioException(
                  requestOptions: RequestOptions(path: url),
                  type: DioExceptionType.cancel,
                  message: 'Download cancelled.',
                );
              }

              sink.add(chunk);
              receivedBytes += chunk.length;

              final downloadedBytes =
                  existingBytes + receivedBytes;

              if (totalBytes > 0) {
                onProgress?.call(
                  (downloadedBytes / totalBytes)
                      .clamp(0.0, 1.0)
                      .toDouble(),
                );
              } else if (expectedBytes > 0) {
                onProgress?.call(
                  (downloadedBytes / expectedBytes)
                      .clamp(0.0, 1.0)
                      .toDouble(),
                );
              }
            }

            await sink.flush();
          } finally {
            await sink.close();
          }

          final savedLength = await partFile.length();

          if (savedLength <= 0) {
            throw DownloadException(
              'Downloaded file is empty for $modelId.',
            );
          }

          // For known catalog entries, reject a clearly truncated transfer.
          if (expectedBytes > 0) {
            final minimumBytes =
                (expectedBytes * 0.70).toInt();

            if (savedLength < minimumBytes) {
              throw DownloadException(
                'Download incomplete for $modelId: '
                '$savedLength bytes received; '
                'at least $minimumBytes expected.',
              );
            }
          }

          final validation = await _validateModelFileDetailed(
            partFile,
            treatMissingAsMissing: false,
          );

          if (validation.status !=
              ModelValidationStatus.validatedOk) {
            throw DownloadException(
              validation.message ??
                  'Downloaded file is not a valid GGUF for $modelId.',
            );
          }

          if (await finalFile.exists()) {
            await finalFile.delete();
          }

          await partFile.rename(finalFile.path);

          final finalLength = await finalFile.length();

          onProgress?.call(1.0);

          return _DownloadResult(
            path: finalFile.path,
            sizeBytes: finalLength,
            status: validation.status,
          );
        } on DioException catch (error) {
          if (CancelToken.isCancel(error) ||
              error.type == DioExceptionType.cancel) {
            throw DownloadException(
              'Download cancelled for $modelId',
            );
          }

          final isTransient =
              _isTransientDownloadError(error);

          if (!isTransient || attempt == _maxDownloadAttempts) {
            final statusCode =
                error.response?.statusCode;

            final responseBody =
                error.response?.data?.toString() ??
                    '<no body>';

            stderr.writeln(
              '[ModelDownloadService] Download failed for '
              '$modelId: HTTP $statusCode – $responseBody',
            );

            rethrow;
          }

          stderr.writeln(
            '[ModelDownloadService] transient download error '
            'for $modelId; preserving .part and retrying '
            '(attempt $attempt/$_maxDownloadAttempts): '
            '${error.message}',
          );

          await Future<void>.delayed(
            Duration(seconds: attempt * 2),
          );
        } on DownloadException {
          rethrow;
        } catch (error) {
          if (attempt == _maxDownloadAttempts) {
            throw DownloadException(
              'Download failed for $modelId: $error',
            );
          }

          stderr.writeln(
            '[ModelDownloadService] unexpected download error '
            'for $modelId; preserving .part and retrying '
            '(attempt $attempt/$_maxDownloadAttempts): $error',
          );

          await Future<void>.delayed(
            Duration(seconds: attempt * 2),
          );
        }
      }

      throw DownloadException(
        'Download failed for $modelId after '
        '$_maxDownloadAttempts attempts.',
      );
    } finally {
      _cancelTokens.remove(modelId);
    }
  }

  bool _isTransientDownloadError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
        return false;
    }
  }

  double _initialProgress({
    required int existingBytes,
    required int expectedBytes,
  }) {
    if (existingBytes <= 0) return 0.0;

    if (expectedBytes > 0) {
      return (existingBytes / expectedBytes)
          .clamp(0.0, 0.99)
          .toDouble();
    }

    return 0.0;
  }

  int? _parseRangeStart(String? contentRange) {
    if (contentRange == null ||
        contentRange.trim().isEmpty) {
      return null;
    }

    final match = RegExp(
      r'bytes\s+(\d+)-(\d+)/',
      caseSensitive: false,
    ).firstMatch(contentRange);

    if (match == null) {
      return null;
    }

    return int.tryParse(match.group(1)!);
  }

  int? _parseRangeTotal(String? contentRange) {
    if (contentRange == null ||
        contentRange.trim().isEmpty) {
      return null;
    }

    final match = RegExp(
      r'bytes\s+\d+-\d+/(\d+)',
      caseSensitive: false,
    ).firstMatch(contentRange);

    if (match == null) {
      return null;
    }

    return int.tryParse(match.group(1)!);
  }

  // ── GGUF import ────────────────────────────────────────────────────────────

  Future<AiModel?> importLocalModel({
    String? existingModelId,
  }) async {
    final result = await _pickGgufFileWithFallback();

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final picked = result.files.single;

    final rawPath = picked.path?.trim();

    if (rawPath == null || rawPath.isEmpty) {
      throw const DownloadException(
        'Selected file is not accessible from the picker.',
      );
    }

    final validation = await _validateModelPath(
      rawPath,
      treatMissingAsMissing: true,
    );

    if (validation.status !=
        ModelValidationStatus.validatedOk) {
      throw DownloadException(
        validation.message ??
            'Selected file is invalid.',
      );
    }

    final resolvedPath = await _normalizePath(rawPath);
    final file = File(resolvedPath);

    final sizeBytes = await file.length();

    final fileName = picked.name.trim().isNotEmpty
        ? picked.name.trim()
        : p.basename(resolvedPath);

    final family = _inferModelFamily(fileName);

    final runtimeModelId = _inferRuntimeModelId(
      fileName: fileName,
      sizeBytes: sizeBytes,
      family: family,
    );

    final identifier =
        await _persistAndroidDocumentUri(
      picked.identifier,
    );

    final fingerprint = _buildModelFingerprint(
      path: resolvedPath,
      identifier: identifier,
    );

    final current =
        await loadImportedModelEntries();

    final existing = existingModelId == null
        ? null
        : current
            .where(
              (model) => model.id == existingModelId,
            )
            .firstOrNull;

    final duplicate = current
        .where(
          (model) =>
              _buildModelFingerprint(
                path: model.localPath,
                identifier: model.externalUri,
              ) ==
              fingerprint,
        )
        .firstOrNull;

    final modelId = existingModelId ??
        duplicate?.id ??
        'local_import_${_uuid.v5(
          Namespace.url.value,
          fingerprint,
        )}';

    final model = AiModel(
      id: modelId,
      displayName: existing?.displayName ??
          _buildImportedDisplayName(
            fileName,
            family,
          ),
      fileName: fileName,
      downloadUrl: '',
      version: 'local',
      sizeBytes: sizeBytes,
      description: _buildImportedDescription(
        fileName,
        family,
      ),
      isDownloaded: true,
      localPath: resolvedPath,
      platformTarget:
          _inferPlatformTarget(runtimeModelId),
      validationStatus:
          ModelValidationStatus.validatedOk,
      source: 'local_import',
      importedAt:
          existing?.importedAt ?? DateTime.now(),
      externalUri: identifier,
      runtimeModelId: runtimeModelId,
      detectedFamily: family,
      sizeCategory: _inferSizeCategory(
        fileName: fileName,
        sizeBytes: sizeBytes,
        runtimeModelId: runtimeModelId,
        family: family,
      ),
    );

    await saveImportedModelEntry(model);

    return model;
  }

  Future<FilePickerResult?>
      _pickGgufFileWithFallback() async {
    try {
      return await _filePicker.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: const ['gguf'],
      );
    } on PlatformException catch (error) {
      if (!_shouldFallbackToAnyPicker(error)) {
        rethrow;
      }

      return _filePicker.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.any,
      );
    }
  }

  bool _shouldFallbackToAnyPicker(
    PlatformException error,
  ) {
    return Platform.isAndroid &&
        error.code ==
            _filePickerPlatformExceptionCode;
  }

  Future<void> deleteModel(AiModel model) async {
    if (model.isImportedModel) {
      return;
    }

    final modelsDir = await _modelsDirectory();

    final file = File(
      '${modelsDir.path}/${model.fileName}',
    );

    final partFile = File('${file.path}.part');

    if (await file.exists()) {
      await file.delete();
    }

    if (await partFile.exists()) {
      await partFile.delete();
    }
  }

  // ── Export ─────────────────────────────────────────────────────────────────

  /// Exports every downloaded GGUF model to the same public model directory
  /// already used by the existing Voice/Model Management infrastructure.
  ///
  /// The operation does not delete or move the private copy. It creates a
  /// public-storage copy, so uninstall/reinstall recovery can reuse the files.
  ///
  /// Returns the number of successfully exported model files.
  Future<int> exportAllDownloadedModelsToPublicStorage({
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const DownloadException(
        'Esportazione modelli disponibile solo su Android.',
      );
    }

    final permissionGranted =
        await _checkAndRequestStoragePermissions();

    if (!permissionGranted) {
      throw const DownloadException(
        'Permessi di archiviazione negati.',
      );
    }

    final publicDir =
        await _pathResolver.ensurePublicModelsDirectory();

    final models = await getAvailableModels();

    final jobs = <_ExportCopyJob>[];

    final seenDestinations = <String>{};

    for (final model in models) {
      if (!model.isDownloaded) {
        continue;
      }

      final localPath =
          model.localPath?.trim();

      if (localPath == null ||
          localPath.isEmpty) {
        continue;
      }

      final source = await _resolveExportSource(
        model,
      );

      if (source == null ||
          !await source.exists()) {
        continue;
      }

      if (!source.path
          .toLowerCase()
          .endsWith('.gguf')) {
        continue;
      }

      final destination = File(
        p.join(
          publicDir.path,
          model.fileName,
        ),
      );

      if (!seenDestinations.add(
        destination.path,
      )) {
        continue;
      }

      jobs.add(
        _ExportCopyJob(
          source: source,
          destination: destination,
        ),
      );
    }

    if (jobs.isEmpty) {
      onProgress?.call(1.0);
      return 0;
    }

    var exported = 0;

    onProgress?.call(0.0);

    for (var index = 0;
        index < jobs.length;
        index++) {
      final job = jobs[index];

      await _copyFileWithProgress(
        source: job.source,
        destination: job.destination,
        onProgress: (fileProgress) {
          final aggregate =
              (index + fileProgress) /
                  jobs.length;

          onProgress?.call(
            aggregate
                .clamp(0.0, 1.0)
                .toDouble(),
          );
        },
      );

      exported++;

      onProgress?.call(
        ((index + 1) / jobs.length)
            .clamp(0.0, 1.0)
            .toDouble(),
      );
    }

    return exported;
  }

  Future<File?> _resolveExportSource(
    AiModel model,
  ) async {
    final localPath =
        model.localPath?.trim();

    if (localPath == null ||
        localPath.isEmpty) {
      return null;
    }

    try {
      final source = File(localPath);

      if (await source.exists()) {
        return source;
      }
    } catch (_) {
      // Fall through to RuntimeModelPathResolver.
    }

    try {
      final resolution =
          await _pathResolver.resolveForRead(
        fileName: p.basename(localPath),
        privateAbsolutePathHint: localPath,
      );

      if (resolution.exists) {
        return resolution.file;
      }
    } catch (_) {
      // Export should skip one inaccessible model rather than abort
      // the entire export operation.
    }

    return null;
  }

  Future<bool>
      _checkAndRequestStoragePermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    if (await Permission
            .manageExternalStorage
            .isGranted ||
        await Permission.storage.isGranted) {
      return true;
    }

    final manageStatus =
        await Permission
            .manageExternalStorage
            .request();

    if (manageStatus.isGranted) {
      return true;
    }

    final storageStatus =
        await Permission.storage.request();

    return storageStatus.isGranted;
  }

  Future<void> _copyFileWithProgress({
    required File source,
    required File destination,
    required void Function(double progress)
        onProgress,
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

    final tempDestination =
        File('${destination.path}.part');

    if (await tempDestination.exists()) {
      await tempDestination.delete();
    }

    final sink = tempDestination.openWrite();

    var copiedBytes = 0;

    try {
      await for (final chunk
          in source.openRead()) {
        sink.add(chunk);

        copiedBytes += chunk.length;

        onProgress(
          (copiedBytes / totalBytes)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
      }

      await sink.flush();
    } finally {
      await sink.close();
    }

    if (await destination.exists()) {
      await destination.delete();
    }

    await tempDestination.rename(
      destination.path,
    );

    onProgress(1.0);
  }

  // ── Version check ──────────────────────────────────────────────────────────

  Future<List<AiModel>> checkForUpdates(
    List<AiModel> currentModels,
  ) async {
    try {
      final response = await _dio.get<String>(
        AppConstants.modelVersionManifestUrl,
        options: Options(
          receiveTimeout:
              const Duration(seconds: 30),
        ),
      );

      if (response.statusCode != 200 ||
          response.data == null) {
        return <AiModel>[];
      }

      final manifest =
          jsonDecode(response.data!)
              as Map<String, dynamic>;

      final updates = <AiModel>[];

      for (final model in currentModels) {
        if (!model.isDownloaded) {
          continue;
        }

        final remoteVersion =
            manifest[model.id]?['version']
                as String?;

        if (remoteVersion != null &&
            remoteVersion != model.version) {
          updates.add(
            model.copyWith(
              version: remoteVersion,
            ),
          );
        }
      }

      return updates;
    } catch (_) {
      return <AiModel>[];
    }
  }

  // ── Selection persistence ───────────────────────────────────────────────────

  Future<void> saveSelectedModel(
    String modelId,
  ) async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      AppConstants.prefSelectedModel,
      modelId,
    );
  }

  Future<String?> loadSelectedModelId() async {
    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getString(
      AppConstants.prefSelectedModel,
    );
  }

  Future<void> markOnboardingDone() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setBool(
      AppConstants.prefOnboardingDone,
      true,
    );
  }

  Future<bool> isOnboardingDone() async {
    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getBool(
          AppConstants.prefOnboardingDone,
        ) ??
        false;
  }

  // ── Custom model persistence ───────────────────────────────────────────────

  static const String _customModelsKey =
      'custom_models';

  static const String _importedModelsKey =
      'imported_models';

  Future<void> saveCustomModelEntry(
    AiModel model,
  ) async {
    final prefs =
        await SharedPreferences.getInstance();

    final current =
        await loadCustomModelEntries();

    final updated = <AiModel>[
      ...current.where(
        (m) => m.id != model.id,
      ),
      model,
    ];

    final json = jsonEncode(
      updated.map(_modelToJson).toList(),
    );

    await prefs.setString(
      _customModelsKey,
      json,
    );
  }

  Future<List<AiModel>>
      loadCustomModelEntries() async {
    final prefs =
        await SharedPreferences.getInstance();

    return _loadStoredModelEntries(
      prefs,
      _customModelsKey,
    );
  }

  Future<void> saveImportedModelEntry(
    AiModel model,
  ) async {
    final prefs =
        await SharedPreferences.getInstance();

    final current =
        await loadImportedModelEntries();

    final updated = <AiModel>[
      ...current.where(
        (m) => m.id != model.id,
      ),
      model,
    ];

    final json = jsonEncode(
      updated.map(_modelToJson).toList(),
    );

    await prefs.setString(
      _importedModelsKey,
      json,
    );
  }

  Future<List<AiModel>>
      loadImportedModelEntries() async {
    final prefs =
        await SharedPreferences.getInstance();

    return _loadStoredModelEntries(
      prefs,
      _importedModelsKey,
    );
  }

  Map<String, dynamic> _modelToJson(
    AiModel model,
  ) {
    return <String, dynamic>{
      'id': model.id,
      'displayName': model.displayName,
      'fileName': model.fileName,
      'downloadUrl': model.downloadUrl,
      'version': model.version,
      'sizeBytes': model.sizeBytes,
      'sizeCategory': model.sizeCategory,
      'description': model.description,
      'localPath': model.localPath,
      'platformTarget': model.platformTarget,
      'source': model.source,
      'importedAt':
          model.importedAt?.toIso8601String(),
      'externalUri': model.externalUri,
      'runtimeModelId': model.runtimeModelId,
      'detectedFamily': model.detectedFamily,
    };
  }

  AiModel _modelFromJson(
    Map<String, dynamic> json,
  ) {
    return AiModel(
      id: json['id'] as String,
      displayName:
          json['displayName'] as String,
      fileName:
          json['fileName'] as String,
      downloadUrl:
          json['downloadUrl'] as String,
      version:
          json['version'] as String,
      sizeBytes:
          (json['sizeBytes'] as num)
              .toInt(),
      sizeCategory:
          json['sizeCategory'] as String?,
      description:
          json['description'] as String,
      isDownloaded: true,
      localPath:
          json['localPath'] as String?,
      platformTarget:
          json['platformTarget'] as String?,
      source:
          (json['source'] as String?) ??
              'custom_url',
      importedAt:
          _parseDateTime(
            json['importedAt']
                as String?,
          ),
      externalUri:
          json['externalUri'] as String?,
      runtimeModelId:
          json['runtimeModelId'] as String?,
      detectedFamily:
          json['detectedFamily'] as String?,
    );
  }

  // ── Validation ─────────────────────────────────────────────────────────────

  Future<_ModelFileValidationResult>
      _validateModelPath(
    String path, {
    bool treatMissingAsMissing = false,
  }) async {
    if (path.trim().isEmpty) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message:
            'Selected model file path is empty.',
      );
    }

    if (!path
        .toLowerCase()
        .endsWith('.gguf')) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message:
            'Selected model is not a GGUF file.',
      );
    }

    return _validateModelFileDetailed(
      File(path),
      treatMissingAsMissing:
          treatMissingAsMissing,
    );
  }

  Future<ModelValidationStatus>
      _validateModelFile(
    File file, {
    bool treatMissingAsMissing = false,
  }) async {
    final result =
        await _validateModelFileDetailed(
      file,
      treatMissingAsMissing:
          treatMissingAsMissing,
    );

    return result.status;
  }

  Future<_ModelFileValidationResult>
      _validateModelFileDetailed(
    File file, {
    bool treatMissingAsMissing = false,
  }) async {
    try {
      if (!await file.exists()) {
        return _ModelFileValidationResult(
          treatMissingAsMissing
              ? ModelValidationStatus.missingFile
              : ModelValidationStatus.invalidModel,
          message:
              'Selected model file does not exist.',
        );
      }

      final length = await file.length();

      if (length < _ggufMagic.length) {
        return const _ModelFileValidationResult(
          ModelValidationStatus.invalidModel,
          message:
              'Selected model file is empty or truncated.',
        );
      }

      final raf = await file.open();

      try {
        final header =
            Uint8List(_ggufMagic.length);

        await raf.readInto(header);

        for (var i = 0;
            i < _ggufMagic.length;
            i++) {
          if (header[i] !=
              _ggufMagic[i]) {
            return const _ModelFileValidationResult(
              ModelValidationStatus.invalidModel,
              message:
                  'Selected model has an invalid GGUF header.',
            );
          }
        }
      } finally {
        await raf.close();
      }

      return const _ModelFileValidationResult(
        ModelValidationStatus.validatedOk,
      );
    } catch (_) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message:
            'Selected model file is not readable.',
      );
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<AiModel> _refreshStoredModel(
    AiModel model,
  ) async {
    final path = model.localPath;

    if (path == null ||
        path.trim().isEmpty) {
      return model.copyWith(
        isDownloaded:
            model.isImportedModel,
        validationStatus:
            model.isImportedModel
                ? ModelValidationStatus
                    .missingFile
                : ModelValidationStatus
                    .notDownloaded,
        sizeCategory:
            model.sizeCategory ??
                _inferSizeCategory(
                  fileName: model.fileName,
                  sizeBytes:
                      model.sizeBytes,
                  runtimeModelId:
                      model.runtimeModelId ??
                          model.id,
                  family:
                      model.detectedFamily,
                ),
      );
    }

    final resolution =
        await _pathResolver.resolveForRead(
      fileName: p.basename(path),
      privateAbsolutePathHint: path,
    );

    final resolvedPath =
        resolution.file.path;

    final exists =
        resolution.exists;

    if (!exists &&
        !model.isImportedModel) {
      return model.copyWith(
        isDownloaded: false,
        validationStatus:
            ModelValidationStatus
                .notDownloaded,
        localPath: path,
        sizeCategory:
            model.sizeCategory ??
                _inferSizeCategory(
                  fileName: model.fileName,
                  sizeBytes:
                      model.sizeBytes,
                  runtimeModelId:
                      model.runtimeModelId ??
                          model.id,
                  family:
                      model.detectedFamily,
                ),
      );
    }

    final validation =
        await _validateModelPath(
      resolvedPath,
      treatMissingAsMissing:
          model.isImportedModel,
    );

    final isMissing =
        validation.status ==
            ModelValidationStatus
                .missingFile;

    return model.copyWith(
      isDownloaded:
          model.isImportedModel
              ? true
              : !isMissing,
      validationStatus:
          validation.status,
      localPath:
          exists ? resolvedPath : path,
      sizeBytes:
          await _safeFileLength(
        resolvedPath,
        fallback: model.sizeBytes,
      ),
      sizeCategory:
          model.sizeCategory ??
              _inferSizeCategory(
                fileName: model.fileName,
                sizeBytes:
                    model.sizeBytes,
                runtimeModelId:
                    model.runtimeModelId ??
                        model.id,
                family:
                    model.detectedFamily,
              ),
    );
  }

  Future<List<AiModel>>
      _loadStoredModelEntries(
    SharedPreferences prefs,
    String key,
  ) async {
    final raw = prefs.getString(key);

    if (raw == null) {
      return <AiModel>[];
    }

    try {
      final list =
          jsonDecode(raw) as List<dynamic>;

      return list
          .map(
            (entry) =>
                _modelFromJson(
              entry as Map<String, dynamic>,
            ),
          )
          .toList();
    } catch (_) {
      return <AiModel>[];
    }
  }

  static DateTime? _parseDateTime(
    String? value,
  ) {
    if (value == null ||
        value.trim().isEmpty) {
      return null;
    }

    return DateTime.tryParse(value);
  }

  Future<int> _safeFileLength(
    String path, {
    required int fallback,
  }) async {
    try {
      return await File(path).length();
    } catch (_) {
      return fallback;
    }
  }

  Future<String> _normalizePath(
    String path,
  ) async {
    try {
      return await File(path)
          .resolveSymbolicLinks();
    } catch (_) {
      return File(path).absolute.path;
    }
  }

  String _buildModelFingerprint({
    String? path,
    String? identifier,
  }) {
    return '${identifier ?? ''}|${path ?? ''}'
        .toLowerCase();
  }

  String? _inferModelFamily(
    String fileName,
  ) {
    final normalized =
        fileName.toLowerCase();

    if (normalized.contains('deepseek')) {
      return 'deepseek';
    }

    if (normalized.contains('qwen')) {
      return 'qwen';
    }

    if (normalized.contains('phi')) {
      return 'phi';
    }

    if (normalized.contains('llama')) {
      return 'llama';
    }

    if (normalized.contains('gemma')) {
      return 'gemma';
    }

    if (normalized.contains(
      'starcoder',
    )) {
      return 'starcoder';
    }

    return null;
  }

  String? _inferRuntimeModelId({
    required String fileName,
    required int sizeBytes,
    String? family,
  }) {
    final normalized =
        fileName.toLowerCase();

    final has7b =
        normalized.contains('7b') ||
        sizeBytes >= 3500000000;

    switch (family) {
      case 'deepseek':
        if (normalized.contains(
          'coder',
        )) {
          return has7b
              ? 'deepseek_coder_6_7b_instruct'
              : 'deepseek_r1_1_5b';
        }

        return has7b
            ? 'deepseek_r1_7b'
            : 'deepseek_r1_1_5b';

      case 'qwen':
        if (normalized.contains(
          'coder',
        )) {
          return has7b
              ? 'qwen2_5_coder_7b_instruct'
              : 'qwen2_5_3b_instruct';
        }

        if (normalized.contains('qwen3')) {
          if (normalized.contains('8b')) {
            return 'qwen3_8b';
          }

          if (normalized.contains('4b')) {
            return 'qwen3_4b';
          }

          return 'qwen3_1_7b';
        }

        return has7b
            ? 'qwen2_5_coder_7b_instruct'
            : 'qwen2_5_3b_instruct';

      case 'phi':
        return 'phi3_5_mini';

      case 'llama':
        if (normalized.contains('3.2')) {
          if (normalized.contains('3b')) {
            return 'llama3_2_3b';
          }

          return 'llama3_2_1b';
        }

        return 'llama_1b';

      case 'gemma':
        return normalized.contains('2b')
            ? 'gemma_2b_it'
            : 'gemma_2b';

      case 'starcoder':
        return 'starcoder2_3b';

      default:
        return null;
    }
  }

  String? _inferPlatformTarget(
    String? runtimeModelId,
  ) {
    switch (runtimeModelId) {
      case 'deepseek_r1_1_5b':
      case 'phi3_5_mini':
      case 'llama_1b':
      case 'llama3_2_1b':
      case 'llama3_2_3b':
      case 'qwen3_1_7b':
      case 'qwen3_4b':
      case 'qwen2_5_3b_instruct':
      case 'starcoder2_3b':
        return 'android';

      case 'deepseek_r1_7b':
      case 'qwen3_8b':
      case 'deepseek_coder_6_7b_instruct':
      case 'qwen2_5_coder_7b_instruct':
        return 'windows';

      case 'deepseek_r1_14b':
      case 'deepseek_r1_32b':
        return 'windows';

      default:
        return 'all';
    }
  }

  String? _inferSizeCategory({
    required String fileName,
    required int sizeBytes,
    String? runtimeModelId,
    String? family,
  }) {
    final normalized =
        fileName.toLowerCase();

    final id =
        (runtimeModelId ?? '')
            .toLowerCase();

    final familyName =
        (family ??
                _inferModelFamily(
                  fileName,
                ) ??
                '')
            .toLowerCase();

    if (id.contains('phi3_5') ||
        normalized.contains('phi-3.5') ||
        normalized.contains('phi3.5')) {
      return '4B';
    }

    if (id.contains(
      'deepseek_coder_6_7b',
    )) {
      return '6.7B';
    }

    if (familyName == 'starcoder') {
      return '3B';
    }

    if (familyName == 'phi') {
      return '4B';
    }

    if (id.contains(
      'qwen2_5_coder_7b',
    )) {
      return '7B';
    }

    if (id.contains(
      'qwen2_5_3b',
    )) {
      return '3B';
    }

    if (id.contains(
      'deepseek_r1_7b',
    )) {
      return '7B';
    }

    if (sizeBytes >= 7000000000) {
      return '7B+';
    }

    if (sizeBytes >= 3500000000) {
      return '4B+';
    }

    if (id.contains('qwen3_1_7b')) {
      return '1.7B';
    }

    if (id.contains('qwen3_4b')) {
      return '4B';
    }

    if (familyName == 'deepseek') {
      return '2B';
    }

    if (familyName == 'qwen') {
      return '2B';
    }

    if (familyName == 'gemma') {
      return '2B';
    }

    if (familyName == 'llama' ||
        normalized.contains('1b')) {
      return '1B';
    }

    if (sizeBytes >= 2000000000) {
      return '2B';
    }

    return '1B';
  }

  String _buildImportedDisplayName(
    String fileName,
    String? family,
  ) {
    final baseName =
        p.basenameWithoutExtension(
      fileName,
    ).replaceAll('_', ' ');

    if (baseName.trim().isNotEmpty) {
      return baseName;
    }

    return family == null
        ? 'Imported GGUF'
        : 'Imported ${family.toUpperCase()}';
  }

  String _buildImportedDescription(
    String fileName,
    String? family,
  ) {
    final prefix = family == null
        ? 'Imported GGUF from device storage'
        : 'Imported ${family.toUpperCase()} GGUF from device storage';

    return '$prefix · ${p.basename(fileName)}';
  }

  Future<String?>
      _persistAndroidDocumentUri(
    String? uri,
  ) async {
    if (!Platform.isAndroid ||
        uri == null ||
        uri.trim().isEmpty ||
        !uri.startsWith('content://')) {
      return uri;
    }

    try {
      return await _androidChannel
              .invokeMethod<String>(
        'persistDocumentUriPermission',
        <String, dynamic>{
          'uri': uri,
        },
      ) ??
          uri;
    } on MissingPluginException {
      return uri;
    } on PlatformException {
      return uri;
    }
  }

  Future<Directory>
      _modelsDirectory() async {
    final base =
        await getApplicationDocumentsDirectory();

    final dir =
        Directory('${base.path}/models');

    if (!await dir.exists()) {
      await dir.create(
        recursive: true,
      );
    }

    return dir;
  }

}

class _DownloadResult {
  const _DownloadResult({
    required this.path,
    required this.sizeBytes,
    required this.status,
  });

  final String path;
  final int sizeBytes;
  final ModelValidationStatus status;
}

class _ExportCopyJob {
  const _ExportCopyJob({
    required this.source,
    required this.destination,
  });

  final File source;
  final File destination;
}
