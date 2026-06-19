import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
/// All heavy-file transfers use [Dio] with a [CancelToken] so that
/// in-progress downloads can be interrupted cleanly.
///
/// IMPORTANT: GGUF model files on Hugging Face public mirrors are downloaded
/// without any [Authorization] header.  API keys must never be attached to
/// these requests – they belong only in online-provider calls (OpenAI, Gemini,
/// etc.) and are handled exclusively by their respective data-sources.
class ModelDownloadService {
  ModelDownloadService({
    Dio? dio,
    FilePicker? filePicker,
    BundledModelRegistryService? bundledModelRegistryService,
  })
      : _dio = dio ?? _buildDownloadDio(),
        _filePicker = filePicker ?? FilePicker.platform,
        _bundledModelRegistryService =
            bundledModelRegistryService ?? const BundledModelRegistryService();

  /// Builds a Dio instance that is explicitly configured for unauthenticated
  /// public-CDN downloads (Hugging Face / GitHub Releases / etc.).
  ///
  /// A dedicated instance is used instead of a shared one so that no
  /// interceptor added elsewhere (e.g. for online AI APIs) can accidentally
  /// inject an [Authorization] header and trigger an HTTP 401 response.
  static Dio _buildDownloadDio() {
    return Dio(
      BaseOptions(
        // Strip any inherited auth headers – downloads are public.
        headers: const <String, dynamic>{},
        followRedirects: true,
        maxRedirects: 10,
      ),
    );
  }

  final Dio _dio;
  final FilePicker _filePicker;
  final BundledModelRegistryService _bundledModelRegistryService;
  final RuntimeModelPathResolver _pathResolver = const RuntimeModelPathResolver();
  final Map<String, CancelToken> _cancelTokens = {};
  static const Uuid _uuid = Uuid();
  static const MethodChannel _androidChannel =
      MethodChannel('com.aiorchestrator/android_intents');

  // ── Model list helpers ──────────────────────────────────────────────────────

  /// Builds the list of [AiModel] objects, checking local disk for each one.
  ///
  /// Merges built-in models from [AppConstants.availableModels] with any
  /// custom models the user has downloaded via [downloadModelFromUrl].
  ///
  /// Each already-downloaded model is validated (file size > 0, GGUF header)
  /// and stamped with the appropriate [ModelValidationStatus].
  Future<List<AiModel>> getAvailableModels() async {
    final modelsDir = await _modelsDirectory();
    final catalog = await _bundledModelRegistryService.loadCatalog();
    final builtIn = await Future.wait(
      catalog.map((m) async {
        final file = File('${modelsDir.path}/${m['fileName']}');
        final resolution = await _pathResolver.resolveForRead(
          fileName: m['fileName'] as String,
          privateAbsolutePathHint: file.path,
        );
        final downloaded = resolution.exists;
        final effectiveFile = resolution.file;
        ModelValidationStatus status;
        if (downloaded) {
          status = await _validateModelFile(effectiveFile);
        } else {
          status = ModelValidationStatus.notDownloaded;
        }
        return AiModel(
          id: m['id'] as String,
          displayName: m['displayName'] as String,
          fileName: m['fileName'] as String,
          downloadUrl: m['downloadUrl'] as String,
          version: m['version'] as String,
          sizeBytes: m['sizeBytes'] as int,
          sizeCategory: m['sizeCategory'] as String? ??
              _inferSizeCategory(
                fileName: m['fileName'] as String,
                sizeBytes: m['sizeBytes'] as int,
                runtimeModelId: m['id'] as String,
              ),
          description: m['description'] as String,
          isDownloaded: downloaded,
          localPath: downloaded ? effectiveFile.path : null,
          platformTarget: m['platformTarget'] as String?,
          validationStatus: status,
        );
      }),
    );

    final custom = await loadCustomModelEntries();
    final imported = await loadImportedModelEntries();
    final verifiedCustom = await Future.wait(custom.map(_refreshStoredModel));
    final verifiedImported = await Future.wait(imported.map(_refreshStoredModel));

    return [...builtIn, ...verifiedCustom, ...verifiedImported];
  }

  // ── Download ────────────────────────────────────────────────────────────────

  /// Downloads [model] to the device's models directory.
  ///
  /// Reports progress (0.0–1.0) via [onProgress].
  /// After a successful transfer the file is validated; the returned model
  /// carries [ModelValidationStatus.validatedOk] or
  /// [ModelValidationStatus.invalidModel] accordingly.
  Future<AiModel> downloadModel(
    AiModel model, {
    void Function(double progress)? onProgress,
  }) async {
    // Pre-validate the URL before touching the network.
    final uri = Uri.tryParse(model.downloadUrl);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw DownloadException(
          'Invalid download URL for ${model.id}: "${model.downloadUrl}"');
    }

    final modelsDir = await _modelsDirectory();
    final filePath = '${modelsDir.path}/${model.fileName}';

    final cancelToken = CancelToken();
    _cancelTokens[model.id] = cancelToken;

    try {
      await _dio.download(
        model.downloadUrl,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
        options: Options(
          receiveTimeout: AppConstants.modelDownloadTimeout,
          // Ensure no Authorization header is sent – these are public files.
          headers: const <String, dynamic>{},
        ),
      );
      _cancelTokens.remove(model.id);

      // Validate the downloaded file before marking it as ready.
      final file = File(filePath);
      final status = await _validateModelFile(file);

      return model.copyWith(
        isDownloaded: true,
        localPath: filePath,
        validationStatus: status,
        sizeCategory: _inferSizeCategory(
          fileName: model.fileName,
          sizeBytes: file.lengthSync(),
          runtimeModelId: model.runtimeModelId ?? model.id,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw DownloadException('Download cancelled for ${model.id}');
      }
      // Log the full server response to help diagnose failures (e.g. disk-full
      // errors, network errors, or unexpected auth challenges).
      final statusCode = e.response?.statusCode;
      final responseBody = e.response?.data?.toString() ?? '<no body>';
      stderr.writeln(
        '[ModelDownloadService] Download failed for ${model.id}: '
        'HTTP $statusCode – $responseBody',
      );
      throw DownloadException(
        'Download failed (HTTP $statusCode): ${e.message}',
      );
    }
  }

  /// Cancels the in-progress download for [modelId].
  void cancelDownload(String modelId) {
    _cancelTokens[modelId]?.cancel('User cancelled');
    _cancelTokens.remove(modelId);
  }

  // ── Custom URL download ─────────────────────────────────────────────────────

  /// Downloads a model from an arbitrary [url] (Hugging Face, Ollama, GitHub…).
  ///
  /// [modelId]    – caller-supplied unique identifier (used for cancellation).
  /// [fileName]   – file name under which the model is stored on disk.
  /// [onProgress] – optional 0.0–1.0 progress callback.
  ///
  /// Returns an [AiModel] representing the freshly downloaded file.
  Future<AiModel> downloadModelFromUrl(
    String url, {
    required String modelId,
    required String displayName,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final modelsDir = await _modelsDirectory();
    final filePath = '${modelsDir.path}/$fileName';

    final cancelToken = CancelToken();
    _cancelTokens[modelId] = cancelToken;

    try {
      await _dio.download(
        url,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
        options: Options(
          receiveTimeout: AppConstants.modelDownloadTimeout,
          // Ensure no Authorization header is sent – these are public files.
          headers: const <String, dynamic>{},
        ),
      );
      _cancelTokens.remove(modelId);

      // Validate the downloaded file and use actual size.
      final file = File(filePath);
      final fileSize = await file.length();
      final status = await _validateModelFile(file);

      final model = AiModel(
        id: modelId,
        displayName: displayName,
        fileName: fileName,
        downloadUrl: url,
        version: '1.0.0',
        sizeBytes: fileSize,
        description: 'Custom model from $url',
        isDownloaded: true,
        localPath: filePath,
        platformTarget: 'all',
        validationStatus: status,
        sizeCategory: _inferSizeCategory(
          fileName: fileName,
          sizeBytes: fileSize,
          runtimeModelId: modelId,
        ),
        source: 'custom_url',
      );
      // Persist the custom model entry so it reappears after app restarts.
      await saveCustomModelEntry(model);
      return model;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw DownloadException('Download cancelled for $modelId');
      }
      // Log the full server response to help diagnose failures.
      final statusCode = e.response?.statusCode;
      final responseBody = e.response?.data?.toString() ?? '<no body>';
      stderr.writeln(
        '[ModelDownloadService] Custom download failed for $modelId: '
        'HTTP $statusCode – $responseBody',
      );
      throw DownloadException(
        'Download failed (HTTP $statusCode): ${e.message}',
      );
    }
  }

  Future<AiModel?> importLocalModel({String? existingModelId}) async {
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
    if (validation.status != ModelValidationStatus.validatedOk) {
      throw DownloadException(validation.message ?? 'Selected file is invalid.');
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
    final identifier = await _persistAndroidDocumentUri(picked.identifier);
    final fingerprint = _buildModelFingerprint(
      path: resolvedPath,
      identifier: identifier,
    );
    final current = await loadImportedModelEntries();
    final existing = existingModelId == null
        ? null
        : current.where((model) => model.id == existingModelId).firstOrNull;
    final duplicate = current
        .where((model) => _buildModelFingerprint(
              path: model.localPath,
              identifier: model.externalUri,
            ) ==
            fingerprint)
        .firstOrNull;
    final modelId = existingModelId ??
        duplicate?.id ??
        'local_import_${_uuid.v5(Namespace.url.value, fingerprint)}';

    final model = AiModel(
      id: modelId,
      displayName:
          existing?.displayName ?? _buildImportedDisplayName(fileName, family),
      fileName: fileName,
      downloadUrl: '',
      version: 'local',
      sizeBytes: sizeBytes,
      description: _buildImportedDescription(fileName, family),
      isDownloaded: true,
      localPath: resolvedPath,
      platformTarget: _inferPlatformTarget(runtimeModelId),
      validationStatus: ModelValidationStatus.validatedOk,
      source: 'local_import',
      importedAt: existing?.importedAt ?? DateTime.now(),
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

  Future<FilePickerResult?> _pickGgufFileWithFallback() async {
    try {
      return await _filePicker.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: const ['gguf'],
      );
    } on PlatformException catch (error) {
      if (!_shouldFallbackToAnyPicker(error)) rethrow;
      return _filePicker.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.any,
      );
    }
  }

  /// Android SAF implementations on some OEM devices reject custom extension
  /// filters in file_picker; when that surfaces as a FilePicker platform
  /// exception we retry with FileType.any and validate the file ourselves.
  bool _shouldFallbackToAnyPicker(PlatformException error) {
    return Platform.isAndroid &&
        error.code == _filePickerPlatformExceptionCode;
  }

  Future<void> deleteModel(AiModel model) async {
    if (model.isImportedModel) {
      return;
    }
    final modelsDir = await _modelsDirectory();
    final file = File('${modelsDir.path}/${model.fileName}');
    if (await file.exists()) {
      await file.delete();
    }
  }

  // ── Version check ───────────────────────────────────────────────────────────

  /// Fetches the remote version manifest and returns locally-present models
  /// whose remote version differs from the cached version.
  Future<List<AiModel>> checkForUpdates(List<AiModel> currentModels) async {
    try {
      final response = await _dio.get<String>(
        AppConstants.modelVersionManifestUrl,
        options: Options(receiveTimeout: const Duration(seconds: 30)),
      );
      if (response.statusCode != 200 || response.data == null) return [];
      final manifest = jsonDecode(response.data!) as Map<String, dynamic>;
      final updates = <AiModel>[];
      for (final model in currentModels) {
        if (!model.isDownloaded) continue;
        final remoteVersion = manifest[model.id]?['version'] as String?;
        if (remoteVersion != null && remoteVersion != model.version) {
          updates.add(model.copyWith(version: remoteVersion));
        }
      }
      return updates;
    } catch (_) {
      return [];
    }
  }

  // ── Selection persistence ───────────────────────────────────────────────────

  Future<void> saveSelectedModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefSelectedModel, modelId);
  }

  Future<String?> loadSelectedModelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefSelectedModel);
  }

  Future<void> markOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingDone, true);
  }

  Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.prefOnboardingDone) ?? false;
  }

  // ── Custom model persistence ──────────────────────────────────────────────

  static const String _customModelsKey = 'custom_models';
  static const String _importedModelsKey = 'imported_models';

  /// Persists [model] metadata to SharedPreferences so custom models survive
  /// app restarts.  Models are stored as a JSON array keyed by [_customModelsKey].
  Future<void> saveCustomModelEntry(AiModel model) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await loadCustomModelEntries();
    final updated = [
      ...current.where((m) => m.id != model.id),
      model,
    ];
    final json = jsonEncode(updated.map(_modelToJson).toList());
    await prefs.setString(_customModelsKey, json);
  }

  /// Returns the list of user-added custom models stored in SharedPreferences.
  Future<List<AiModel>> loadCustomModelEntries() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadStoredModelEntries(prefs, _customModelsKey);
  }

  Future<void> saveImportedModelEntry(AiModel model) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await loadImportedModelEntries();
    final updated = [
      ...current.where((m) => m.id != model.id),
      model,
    ];
    final json = jsonEncode(updated.map(_modelToJson).toList());
    await prefs.setString(_importedModelsKey, json);
  }

  Future<List<AiModel>> loadImportedModelEntries() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadStoredModelEntries(prefs, _importedModelsKey);
  }

  Map<String, dynamic> _modelToJson(AiModel m) => {
        'id': m.id,
        'displayName': m.displayName,
        'fileName': m.fileName,
        'downloadUrl': m.downloadUrl,
        'version': m.version,
        'sizeBytes': m.sizeBytes,
        'sizeCategory': m.sizeCategory,
        'description': m.description,
        'localPath': m.localPath,
        'platformTarget': m.platformTarget,
        'source': m.source,
        'importedAt': m.importedAt?.toIso8601String(),
        'externalUri': m.externalUri,
        'runtimeModelId': m.runtimeModelId,
        'detectedFamily': m.detectedFamily,
        // validationStatus is intentionally not persisted – it is recomputed
        // from the file on disk each time getAvailableModels() is called.
      };

  AiModel _modelFromJson(Map<String, dynamic> j) => AiModel(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        fileName: j['fileName'] as String,
        downloadUrl: j['downloadUrl'] as String,
        version: j['version'] as String,
        sizeBytes: (j['sizeBytes'] as num).toInt(),
        sizeCategory: j['sizeCategory'] as String?,
        description: j['description'] as String,
        isDownloaded: true,
        localPath: j['localPath'] as String?,
        platformTarget: j['platformTarget'] as String?,
        source: (j['source'] as String?) ?? 'custom_url',
        importedAt: _parseDateTime(j['importedAt'] as String?),
        externalUri: j['externalUri'] as String?,
        runtimeModelId: j['runtimeModelId'] as String?,
        detectedFamily: j['detectedFamily'] as String?,
        // validationStatus starts as null and is populated by getAvailableModels().
      );

  // ── Validation ──────────────────────────────────────────────────────────────

  /// Validates a GGUF model file using lightweight disk checks only.
  Future<_ModelFileValidationResult> _validateModelPath(
    String path, {
    bool treatMissingAsMissing = false,
  }) async {
    if (path.trim().isEmpty) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message: 'Selected model file path is empty.',
      );
    }
    if (!path.toLowerCase().endsWith('.gguf')) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message: 'Selected model is not a GGUF file.',
      );
    }
    return _validateModelFileDetailed(
      File(path),
      treatMissingAsMissing: treatMissingAsMissing,
    );
  }

  Future<ModelValidationStatus> _validateModelFile(
    File file, {
    bool treatMissingAsMissing = false,
  }) async {
    final result = await _validateModelFileDetailed(
      file,
      treatMissingAsMissing: treatMissingAsMissing,
    );
    return result.status;
  }

  Future<_ModelFileValidationResult> _validateModelFileDetailed(
    File file, {
    bool treatMissingAsMissing = false,
  }) async {
    try {
      if (!await file.exists()) {
        return _ModelFileValidationResult(
          treatMissingAsMissing
              ? ModelValidationStatus.missingFile
              : ModelValidationStatus.invalidModel,
          message: 'Selected model file does not exist.',
        );
      }

      final length = await file.length();
      if (length < _ggufMagic.length) {
        return const _ModelFileValidationResult(
          ModelValidationStatus.invalidModel,
          message: 'Selected model file is empty or truncated.',
        );
      }

      final raf = await file.open();
      try {
        final header = Uint8List(_ggufMagic.length);
        await raf.readInto(header);
        for (var i = 0; i < _ggufMagic.length; i++) {
          if (header[i] != _ggufMagic[i]) {
            return const _ModelFileValidationResult(
              ModelValidationStatus.invalidModel,
              message: 'Selected model has an invalid GGUF header.',
            );
          }
        }
      } finally {
        await raf.close();
      }

      return const _ModelFileValidationResult(ModelValidationStatus.validatedOk);
    } catch (_) {
      return const _ModelFileValidationResult(
        ModelValidationStatus.invalidModel,
        message: 'Selected model file is not readable.',
      );
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<AiModel> _refreshStoredModel(AiModel model) async {
    final path = model.localPath;
    if (path == null || path.trim().isEmpty) {
      return model.copyWith(
        isDownloaded: model.isImportedModel,
        validationStatus: model.isImportedModel
            ? ModelValidationStatus.missingFile
            : ModelValidationStatus.notDownloaded,
        sizeCategory: model.sizeCategory ??
            _inferSizeCategory(
              fileName: model.fileName,
              sizeBytes: model.sizeBytes,
              runtimeModelId: model.runtimeModelId ?? model.id,
              family: model.detectedFamily,
            ),
        );
    }
    final resolution = await _pathResolver.resolveForRead(
      fileName: p.basename(path),
      privateAbsolutePathHint: path,
    );
    final resolvedPath = resolution.file.path;
    final exists = resolution.exists;
    if (!exists && !model.isImportedModel) {
      return model.copyWith(
        isDownloaded: false,
        validationStatus: ModelValidationStatus.notDownloaded,
        localPath: path,
        sizeCategory: model.sizeCategory ??
            _inferSizeCategory(
              fileName: model.fileName,
              sizeBytes: model.sizeBytes,
              runtimeModelId: model.runtimeModelId ?? model.id,
              family: model.detectedFamily,
            ),
      );
    }
    final validation = await _validateModelPath(
      resolvedPath,
      treatMissingAsMissing: model.isImportedModel,
    );
    final isMissing = validation.status == ModelValidationStatus.missingFile;
    return model.copyWith(
      isDownloaded: model.isImportedModel ? true : !isMissing,
      validationStatus: validation.status,
      localPath: exists ? resolvedPath : path,
      sizeBytes: await _safeFileLength(resolvedPath, fallback: model.sizeBytes),
      sizeCategory: model.sizeCategory ??
          _inferSizeCategory(
            fileName: model.fileName,
            sizeBytes: model.sizeBytes,
            runtimeModelId: model.runtimeModelId ?? model.id,
            family: model.detectedFamily,
          ),
    );
  }

  Future<List<AiModel>> _loadStoredModelEntries(
    SharedPreferences prefs,
    String key,
  ) async {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => _modelFromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static DateTime? _parseDateTime(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return DateTime.tryParse(value);
  }

  Future<int> _safeFileLength(String path, {required int fallback}) async {
    try {
      return await File(path).length();
    } catch (_) {
      return fallback;
    }
  }

  Future<String> _normalizePath(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } catch (_) {
      return File(path).absolute.path;
    }
  }

  String _buildModelFingerprint({String? path, String? identifier}) =>
      '${identifier ?? ''}|${path ?? ''}'.toLowerCase();

  String? _inferModelFamily(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.contains('deepseek')) return 'deepseek';
    if (normalized.contains('qwen')) return 'qwen';
    if (normalized.contains('phi')) return 'phi';
    if (normalized.contains('llama')) return 'llama';
    if (normalized.contains('gemma')) return 'gemma';
    return null;
  }

  String? _inferRuntimeModelId({
    required String fileName,
    required int sizeBytes,
    String? family,
  }) {
    final normalized = fileName.toLowerCase();
    final has7b = normalized.contains('7b') || sizeBytes >= 3500000000;
    switch (family) {
      case 'deepseek':
        return has7b ? 'deepseek_r1_7b' : 'deepseek_r1_1_5b';
      case 'qwen':
        return has7b ? 'deepseek_r1_7b' : 'qwen3_1_7b';
      case 'phi':
        return 'phi3_5_mini';
      case 'llama':
        return 'llama_1b';
      case 'gemma':
        return normalized.contains('it') || normalized.contains('instruct')
            ? 'gemma_2_2b_it'
            : 'gemma_2b';
      default:
        return null;
    }
  }

  String? _inferPlatformTarget(String? runtimeModelId) {
    if (runtimeModelId == 'deepseek_r1_1_5b') return 'android';
    if (runtimeModelId == 'deepseek_r1_7b') return 'windows';
    if (runtimeModelId == 'phi3_5_mini') return 'android';
    return 'all';
  }

  String? _inferSizeCategory({
    required String fileName,
    required int sizeBytes,
    String? runtimeModelId,
    String? family,
  }) {
    final normalized = fileName.toLowerCase();
    final id = (runtimeModelId ?? '').toLowerCase();
    final familyName = (family ?? _inferModelFamily(fileName) ?? '').toLowerCase();

    if (id.contains('phi3_5') ||
        normalized.contains('phi-3.5') ||
        normalized.contains('phi3.5')) {
      return '4B';
    }
    if (familyName == 'phi') return '4B';
    if (id.contains('deepseek_r1_7b')) return '7B';
    if (sizeBytes >= 7000000000) return '7B';
    if (sizeBytes >= 3500000000) return '4B';
    if (id.contains('qwen3_1_7b')) return '2B';
    if (familyName == 'deepseek') return '2B';
    if (familyName == 'qwen') return '2B';
    if (familyName == 'gemma') return '2B';
    if (familyName == 'llama' || normalized.contains('1b')) return '1B';
    if (sizeBytes >= 2000000000) return '2B';
    return '1B';
  }

  String _buildImportedDisplayName(String fileName, String? family) {
    final baseName = p.basenameWithoutExtension(fileName).replaceAll('_', ' ');
    if (baseName.trim().isNotEmpty) return baseName;
    return family == null ? 'Imported GGUF' : 'Imported ${family.toUpperCase()}';
  }

  String _buildImportedDescription(String fileName, String? family) {
    final prefix = family == null
        ? 'Imported GGUF from device storage'
        : 'Imported ${family.toUpperCase()} GGUF from device storage';
    return '$prefix · ${p.basename(fileName)}';
  }

  Future<String?> _persistAndroidDocumentUri(String? uri) async {
    if (!Platform.isAndroid ||
        uri == null ||
        uri.trim().isEmpty ||
        !uri.startsWith('content://')) {
      return uri;
    }
    try {
      return await _androidChannel.invokeMethod<String>(
            'persistDocumentUriPermission',
            <String, dynamic>{'uri': uri},
          ) ??
          uri;
    } on MissingPluginException {
      return uri;
    } on PlatformException {
      return uri;
    }
  }

  Future<Directory> _modelsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/models');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
