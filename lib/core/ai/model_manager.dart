import 'dart:io';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';

/// Detects the current platform and selects the best AI model.
///
/// Preference order:
/// 1. A model that explicitly targets the current platform.
/// 2. A model whose [AiModel.platformTarget] is `null` or `'all'`.
/// 3. The first model in the list as a final fallback.
class ModelManager {
  const ModelManager();

  static const int _desktopFallbackThresholdBytes = 2300000000;

  // ── Platform detection ────────────────────────────────────────────────────

  /// Returns the platform tag for the current OS.
  ///
  /// Possible values: `'android'`, `'windows'`, `'all'`.
  String get currentPlatformTag {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return 'all';
  }

  /// `true` when the app is running on a mobile (Android / iOS) device.
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Human-readable label that describes the recommended model tier for the UI.
  ///
  /// Examples:
  /// - Android → `"Mobile Coder (1B-4B)"`
  /// - Windows → `"Senior Architect (7B+)"`
  /// - other   → `"Standard"`
  String get platformModelLabel {
    if (Platform.isAndroid) return 'Mobile Coder (1B-4B)';
    if (Platform.isWindows) return 'Senior Architect (7B+)';
    return 'Standard';
  }

  // ── Model selection ───────────────────────────────────────────────────────

  /// Returns the ID of the model that best matches the current platform from
  /// [models], or `null` when the list is empty.
  String? getRecommendedModelId(List<AiModel> models) {
    if (models.isEmpty) return null;

    final tag = currentPlatformTag;

    // 1. Platform-specific match.
    final specific =
        models.where((m) => m.platformTarget == tag).firstOrNull;
    if (specific != null) return specific.id;

    // 2. Universal match.
    final universal = models
        .where((m) => m.platformTarget == null || m.platformTarget == 'all')
        .firstOrNull;
    if (universal != null) return universal.id;

    // 3. Fallback: first available.
    return models.first.id;
  }

  /// Returns the [AiModel] that best matches the current platform from
  /// [models], or `null` when the list is empty.
  AiModel? getRecommendedModel(List<AiModel> models) {
    final id = getRecommendedModelId(models);
    if (id == null) return null;
    return models.where((m) => m.id == id).firstOrNull;
  }

  /// Returns `true` if [model] is the recommended choice for the current
  /// platform.
  bool isRecommended(AiModel model, List<AiModel> allModels) =>
      getRecommendedModelId(allModels) == model.id;

  /// Returns `true` when [model] is considered desktop-class for filtering.
  ///
  /// The decision prefers an explicit platform target, then the declared size
  /// category, and only falls back to raw file size when the catalog metadata
  /// is missing.
  bool isDesktopModel(AiModel model) {
    final target = (model.platformTarget ?? 'all').toLowerCase();
    if (target == 'windows' ||
        target == 'linux' ||
        target == 'macos' ||
        target == 'desktop' ||
        target == 'pc') {
      return true;
    }

    final category = parseModelSizeCategory(model.sizeCategory);
    if (category != null) {
      return category >= 7;
    }

    return model.sizeBytes >= _desktopFallbackThresholdBytes;
  }

  /// Parses a category label like `4B` or `3.8B` into a numeric tier.
  static int? parseModelSizeCategory(String? value) {
    final normalized = value?.trim().toUpperCase() ?? '';
    if (normalized.isEmpty) return null;
    final match = RegExp(r'(\d+(?:\.\d+)?)\s*B').firstMatch(normalized);
    if (match == null) return null;
    return double.tryParse(match.group(1)!)?.round();
  }
}
