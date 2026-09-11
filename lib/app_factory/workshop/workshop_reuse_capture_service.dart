import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';

/// Promotes verified Workshop output into the reusable local catalog.
///
/// Promotion is explicit and conservative. Failed or partially verified work
/// must never poison the offline-first knowledge base.
final class WorkshopReuseCaptureService {
  const WorkshopReuseCaptureService({
    this.minimumValidationScore = 0.8,
  }) : assert(minimumValidationScore >= 0 && minimumValidationScore <= 1);

  final double minimumValidationScore;

  /// Generic verified-output capture used by production build/emission bridges.
  WorkshopReusableAsset? captureVerifiedOutput({
    required String id,
    required String name,
    required String description,
    required double validationScore,
    required WorkshopReusableAssetOrigin origin,
    required WorkshopReusableAssetKind kind,
    String? target,
    String? artifactPath,
    String? sourceProjectId,
    String? sourceTaskId,
    List<String> tags = const <String>[],
    List<String> capabilities = const <String>[],
    List<String> entryPaths = const <String>[],
    DateTime? createdAt,
  }) {
    if (validationScore < minimumValidationScore) return null;

    final normalizedId = id.trim();
    final normalizedName = name.trim();
    final normalizedDescription = description.trim();
    if (normalizedId.isEmpty ||
        normalizedName.isEmpty ||
        normalizedDescription.isEmpty) {
      return null;
    }

    return WorkshopReusableAsset(
      id: normalizedId,
      name: normalizedName,
      kind: kind,
      origin: origin,
      description: normalizedDescription,
      sourceProjectId: _normalized(sourceProjectId),
      sourceTaskId: _normalized(sourceTaskId),
      target: _normalized(target),
      artifactPath: _normalized(artifactPath),
      tags: _normalizedList(tags),
      capabilities: _normalizedList(capabilities),
      entryPaths: _normalizedList(entryPaths),
      validationScore: validationScore.clamp(0.0, 1.0).toDouble(),
      createdAt: createdAt,
    );
  }

  WorkshopReusableAsset? captureEmission({
    required WorkshopAppEmissionPackage package,
    required double validationScore,
    required String description,
    required List<String> capabilities,
    List<String> tags = const <String>[],
    List<String> entryPaths = const <String>[],
    String? sourceProjectId,
    String? sourceTaskId,
    WorkshopReusableAssetKind kind = WorkshopReusableAssetKind.projectTemplate,
  }) {
    if (!package.isReady) return null;

    final name = package.appName?.trim();
    return captureVerifiedOutput(
      id: 'emission:${package.id.trim()}',
      name: name == null || name.isEmpty ? package.requestId : name,
      kind: kind,
      origin: WorkshopReusableAssetOrigin.completedProject,
      description: description,
      sourceProjectId: sourceProjectId,
      sourceTaskId: sourceTaskId,
      target: package.target,
      artifactPath: package.artifactPath,
      tags: tags,
      capabilities: capabilities,
      entryPaths: entryPaths,
      validationScore: validationScore,
      createdAt: package.createdAt,
    );
  }

  bool captureAndRegister({
    required WorkshopReuseLibrary library,
    required WorkshopAppEmissionPackage package,
    required double validationScore,
    required String description,
    required List<String> capabilities,
    List<String> tags = const <String>[],
    List<String> entryPaths = const <String>[],
    String? sourceProjectId,
    String? sourceTaskId,
    WorkshopReusableAssetKind kind = WorkshopReusableAssetKind.projectTemplate,
  }) {
    final asset = captureEmission(
      package: package,
      validationScore: validationScore,
      description: description,
      capabilities: capabilities,
      tags: tags,
      entryPaths: entryPaths,
      sourceProjectId: sourceProjectId,
      sourceTaskId: sourceTaskId,
      kind: kind,
    );

    if (asset == null) return false;
    library.register(asset);
    return true;
  }

  static String? _normalized(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _normalizedList(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isEmpty) continue;
      final key = normalized.toLowerCase();
      if (seen.add(key)) result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }
}
