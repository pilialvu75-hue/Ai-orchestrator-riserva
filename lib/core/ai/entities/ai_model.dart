import 'package:equatable/equatable.dart';

/// Validation state of an on-device model file.
///
/// [notDownloaded]   – model has not been downloaded yet.
/// [downloading]     – model download is currently in progress.
/// [validatedOk]     – file exists, size > 0, and the GGUF magic header is correct.
/// [invalidModel]    – file exists but failed one or more validation checks
///                     (empty, truncated, or wrong format).
/// [updateAvailable] – model is valid but a newer version exists on the server.
enum ModelValidationStatus {
  notDownloaded,
  downloading,
  validatedOk,
  invalidModel,
  missingFile,
  updateAvailable,
}

/// Describes one of the supported offline AI models.
///
/// This is a core contract used by the orchestration layer, model manager,
/// and local AI provider implementations.
class AiModel extends Equatable {
  const AiModel({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.downloadUrl,
    required this.version,
    required this.sizeBytes,
    required this.description,
    this.sizeCategory,
    this.isDownloaded = false,
    this.localPath,
    this.platformTarget,
    this.validationStatus,
    this.source = 'catalog',
    this.importedAt,
    this.externalUri,
    this.runtimeModelId,
    this.detectedFamily,
  });

  /// Unique model identifier (e.g. `'gemma_2b'`).
  final String id;

  /// Human-readable name shown in the UI.
  final String displayName;

  /// GGUF file name used when saving to disk.
  final String fileName;

  /// Remote URL from which the model file is fetched.
  final String downloadUrl;

  /// Semantic version string (e.g. `'1.0.0'`).
  final String version;

  /// Expected download size in bytes.
  final int sizeBytes;

  /// Categorical model size label (e.g. `1B`, `2B`, `4B`, `7B`).
  final String? sizeCategory;

  /// Short description shown in the UI.
  final String description;

  /// Whether the model file already exists on this device.
  final bool isDownloaded;

  /// Absolute path to the model file, or `null` if not yet downloaded.
  final String? localPath;

  /// Target platform for this model: `'android'`, `'windows'`, or `null`/`'all'`
  /// for universal models.  A `null` value is treated as universally compatible.
  final String? platformTarget;

  /// Result of the post-download or startup validation check.
  ///
  /// `null` means the model has not yet been validated in the current session.
  /// Use [ModelValidationStatus] values to distinguish between a good file,
  /// a corrupt/empty file, and a model that has not been downloaded.
  final ModelValidationStatus? validationStatus;

  /// Source registry for this model (`catalog`, `custom_url`, `local_import`).
  final String source;

  /// Timestamp recorded when a model is imported from device storage.
  final DateTime? importedAt;

  /// Persistent Android SAF/content URI when one is available.
  final String? externalUri;

  /// Built-in runtime model identifier reused for prompt templates/runtime
  /// compatibility. Falls back to [id] when null.
  final String? runtimeModelId;

  /// Best-effort family inferred from file name (e.g. llama, qwen, gemma).
  final String? detectedFamily;

  String get effectiveRuntimeModelId => runtimeModelId ?? id;

  bool get isImportedModel => source == 'local_import';

  AiModel copyWith({
    String? id,
    String? displayName,
    String? fileName,
    String? downloadUrl,
    String? version,
    int? sizeBytes,
    String? sizeCategory,
    String? description,
    bool? isDownloaded,
    String? localPath,
    String? platformTarget,
    ModelValidationStatus? validationStatus,
    String? source,
    DateTime? importedAt,
    String? externalUri,
    String? runtimeModelId,
    String? detectedFamily,
    bool clearValidationStatus = false,
  }) {
    return AiModel(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      fileName: fileName ?? this.fileName,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      version: version ?? this.version,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sizeCategory: sizeCategory ?? this.sizeCategory,
      description: description ?? this.description,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      localPath: localPath ?? this.localPath,
      platformTarget: platformTarget ?? this.platformTarget,
      validationStatus: clearValidationStatus
          ? null
          : (validationStatus ?? this.validationStatus),
      source: source ?? this.source,
      importedAt: importedAt ?? this.importedAt,
      externalUri: externalUri ?? this.externalUri,
      runtimeModelId: runtimeModelId ?? this.runtimeModelId,
      detectedFamily: detectedFamily ?? this.detectedFamily,
    );
  }

  @override
  List<Object?> get props => [
        id,
        displayName,
        fileName,
        downloadUrl,
        version,
        sizeBytes,
        sizeCategory,
        description,
        isDownloaded,
        localPath,
        platformTarget,
        validationStatus,
        source,
        importedAt,
        externalUri,
        runtimeModelId,
        detectedFamily,
      ];

  @override
  String toString() =>
      'AiModel(id: $id, version: $version, isDownloaded: $isDownloaded, '
      'platform: $platformTarget, size: $sizeCategory, source: $source, '
      'validation: $validationStatus)';
}
