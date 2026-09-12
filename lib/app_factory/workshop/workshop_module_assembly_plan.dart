import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';

enum WorkshopAssemblyRequirementKind {
  dependency,
  configuration,
  nativeConfiguration,
  permission,
  secret,
  migration,
  manualReview,
}

enum WorkshopAssemblyConflictKind {
  missingPackage,
  packagePinMismatch,
  incompatiblePackage,
  unsafeTargetPath,
  duplicateTargetPath,
  existingDifferentContent,
}

/// One file from a Library asset after transport/adaptation metadata has mapped
/// it to a project-relative target path.
///
/// This is deliberately not a raw Library transport model. The future bridge
/// owns artifact download/integrity verification and then produces this small,
/// deterministic assembly surface for the Cantiere.
final class WorkshopReusableModuleFile {
  const WorkshopReusableModuleFile({
    required this.sourcePath,
    required this.targetPath,
    required this.content,
  });

  final String sourcePath;
  final String targetPath;
  final String content;
}

/// Integration work that cannot safely be represented as blind file copying.
///
/// Dependencies, permissions, native configuration and secrets stay explicit
/// so the normal Engineer/Reviewer/validation/owner-approval flow can adapt
/// them instead of a reusable module silently editing project-wide files.
final class WorkshopAssemblyRequirement {
  const WorkshopAssemblyRequirement({
    required this.kind,
    required this.description,
    this.required = true,
  });

  final WorkshopAssemblyRequirementKind kind;
  final String description;
  final bool required;

  String get stableKey => '${kind.name}|$required|${description.trim()}';

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'description': description,
        'required': required,
      };
}

/// Bridge-neutral payload for one exact certified Library asset version.
///
/// Asset versions remain pinned. Assembly never replaces this package with a
/// different version merely because a newer one exists.
final class WorkshopReusableModulePackage {
  const WorkshopReusableModulePackage({
    required this.assetId,
    required this.version,
    required this.capabilities,
    required this.contracts,
    required this.files,
    this.requirements = const <WorkshopAssemblyRequirement>[],
    this.artifactDigest,
  });

  final String assetId;
  final String version;
  final List<String> capabilities;
  final List<String> contracts;
  final List<WorkshopReusableModuleFile> files;
  final List<WorkshopAssemblyRequirement> requirements;

  /// Integrity digest verified by the future Cantiere <-> Library bridge.
  /// Assembly keeps it for traceability but does not pretend to verify remote
  /// bytes itself.
  final String? artifactDigest;

  String get pin => '$assetId@$version';
}

final class WorkshopAssemblyConflict {
  const WorkshopAssemblyConflict({
    required this.kind,
    required this.pin,
    required this.reason,
    this.path,
  });

  final WorkshopAssemblyConflictKind kind;
  final String pin;
  final String reason;
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'pin': pin,
        'path': path,
        'reason': reason,
      };
}

final class WorkshopModuleAssemblyPlan {
  const WorkshopModuleAssemblyPlan({
    required this.projectId,
    required this.generatedAt,
    required this.pins,
    required this.changes,
    required this.requirements,
    required this.conflicts,
    required this.identicalExistingPaths,
  });

  final String projectId;
  final DateTime generatedAt;
  final List<String> pins;

  /// Safe, addition-only changes. Existing different files are conflicts and
  /// never become automatic modifications here.
  final List<WorkspaceFileChange> changes;
  final List<WorkshopAssemblyRequirement> requirements;
  final List<WorkshopAssemblyConflict> conflicts;
  final List<String> identicalExistingPaths;

  bool get hasBlockingConflicts => conflicts.isNotEmpty;

  bool get requiresAdaptation =>
      hasBlockingConflicts || requirements.any((item) => item.required);

  bool get isReadyForSafeStaging => !hasBlockingConflicts;

  /// Produces a normal Workshop proposal so reusable files enter exactly the
  /// same VirtualWorkspace -> validation -> owner approval -> apply gates as
  /// newly generated code.
  ///
  /// Conflicting assemblies cannot create a proposal because doing so could
  /// hide an overwrite decision. Required adaptation requirements are retained
  /// as validation notes and must be handled by later Workshop stages.
  WorkshopChangeProposal buildChangeProposal({
    required String requestId,
  }) {
    if (hasBlockingConflicts) {
      throw StateError(
        'Module assembly has blocking conflicts and cannot be staged safely.',
      );
    }

    final notes = requirements
        .where((item) => item.required)
        .map((item) => '[${item.kind.name}] ${item.description}')
        .toList(growable: false);
    final warnings = requirements
        .where((item) => !item.required)
        .map((item) => '[${item.kind.name}] ${item.description}')
        .toList(growable: false);

    return WorkshopChangeProposal(
      requestId: requestId,
      summary: 'Stage certified reusable modules',
      explanation: pins.isEmpty
          ? 'No reusable Library module requires staging.'
          : 'Stage pinned certified Library modules: ${pins.join(', ')}.',
      analysis:
          'Reusable module assembly only adds non-conflicting files. Project-wide '
          'dependency/configuration/native adaptation remains explicit and must '
          'pass the normal Workshop validation and approval gates.',
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
      validationNotes: List<String>.unmodifiable(notes),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'projectId': projectId,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'pins': pins,
        'changes': changes
            .map(
              (item) => <String, Object?>{
                'path': item.path,
                'type': item.type.name,
              },
            )
            .toList(growable: false),
        'requirements':
            requirements.map((item) => item.toJson()).toList(growable: false),
        'conflicts': conflicts.map((item) => item.toJson()).toList(growable: false),
        'identicalExistingPaths': identicalExistingPaths,
        'requiresAdaptation': requiresAdaptation,
      };
}

/// Prepares certified reused assets for the existing guarded Workshop change
/// pipeline without touching the real workspace.
///
/// Safety rules:
/// - consumes only `reuse` decisions from the reuse-first planner;
/// - requires the exact pinned package selected by that decision;
/// - rejects unsafe or project-external target paths;
/// - never deletes files;
/// - never overwrites an existing different file;
/// - never lets two modules claim the same target path;
/// - represents cross-cutting dependency/config/native work as explicit
///   adaptation requirements rather than blind edits.
final class WorkshopModuleAssemblyPlanner {
  const WorkshopModuleAssemblyPlanner();

  WorkshopModuleAssemblyPlan plan({
    required WorkshopProjectReusePlan reusePlan,
    required Map<String, WorkshopReusableModulePackage> packagesByPin,
    required Map<String, String> workspaceSnapshot,
  }) {
    final pins = <String>[];
    final changes = <WorkspaceFileChange>[];
    final conflicts = <WorkshopAssemblyConflict>[];
    final identical = <String>[];
    final requirementsByKey = <String, WorkshopAssemblyRequirement>{};
    final claimedTargets = <String, String>{};
    final stagedPins = <String>{};

    final decisions = reusePlan.decisions
        .where((item) => item.action == WorkshopCapabilityReuseAction.reuse)
        .toList(growable: false)
      ..sort((left, right) =>
          left.need.capabilityId.compareTo(right.need.capabilityId));

    for (final decision in decisions) {
      final candidate = decision.candidate;
      if (candidate == null) {
        conflicts.add(
          WorkshopAssemblyConflict(
            kind: WorkshopAssemblyConflictKind.missingPackage,
            pin: decision.need.capabilityId,
            reason: 'Reuse decision has no selected Library candidate.',
          ),
        );
        continue;
      }

      final pin = candidate.pin;
      final package = packagesByPin[pin];
      if (package == null) {
        conflicts.add(
          WorkshopAssemblyConflict(
            kind: WorkshopAssemblyConflictKind.missingPackage,
            pin: pin,
            reason: 'Exact selected Library package is not available locally.',
          ),
        );
        continue;
      }

      if (package.pin != pin) {
        conflicts.add(
          WorkshopAssemblyConflict(
            kind: WorkshopAssemblyConflictKind.packagePinMismatch,
            pin: pin,
            reason: 'Package identity ${package.pin} does not match selected $pin.',
          ),
        );
        continue;
      }

      if (!package.capabilities.contains(decision.need.capabilityId) ||
          !package.contracts.contains(decision.need.preferredContractId)) {
        conflicts.add(
          WorkshopAssemblyConflict(
            kind: WorkshopAssemblyConflictKind.incompatiblePackage,
            pin: pin,
            reason:
                'Package does not provide ${decision.need.capabilityId} / '
                '${decision.need.preferredContractId}.',
          ),
        );
        continue;
      }

      // One certified package may intentionally satisfy several project
      // capabilities. Validate every selected capability/contract above, but
      // stage the exact asset pin only once so its files do not collide with
      // themselves.
      if (!stagedPins.add(pin)) {
        continue;
      }

      pins.add(pin);
      for (final requirement in package.requirements) {
        final description = requirement.description.trim();
        if (description.isEmpty) {
          continue;
        }
        requirementsByKey.putIfAbsent(requirement.stableKey, () => requirement);
      }

      final files = package.files.toList(growable: false)
        ..sort((left, right) => left.targetPath.compareTo(right.targetPath));

      for (final file in files) {
        final targetPath = file.targetPath.trim();
        if (!_isSafeTargetPath(targetPath)) {
          conflicts.add(
            WorkshopAssemblyConflict(
              kind: WorkshopAssemblyConflictKind.unsafeTargetPath,
              pin: pin,
              path: targetPath,
              reason: 'Reusable module target path is outside the safe project surface.',
            ),
          );
          continue;
        }

        final previousClaim = claimedTargets[targetPath];
        if (previousClaim != null) {
          conflicts.add(
            WorkshopAssemblyConflict(
              kind: WorkshopAssemblyConflictKind.duplicateTargetPath,
              pin: pin,
              path: targetPath,
              reason: 'Target path is already claimed by $previousClaim.',
            ),
          );
          continue;
        }
        claimedTargets[targetPath] = pin;

        final existing = workspaceSnapshot[targetPath];
        if (existing != null) {
          if (existing == file.content) {
            identical.add(targetPath);
          } else {
            conflicts.add(
              WorkshopAssemblyConflict(
                kind: WorkshopAssemblyConflictKind.existingDifferentContent,
                pin: pin,
                path: targetPath,
                reason:
                    'Workspace already contains different content; adaptation is required.',
              ),
            );
          }
          continue;
        }

        changes.add(
          WorkspaceFileChange(
            path: targetPath,
            type: WorkspaceChangeType.addition,
            afterContent: file.content,
          ),
        );
      }
    }

    pins.sort();
    changes.sort((left, right) => left.path.compareTo(right.path));
    conflicts.sort(_compareConflict);
    identical.sort();
    final requirements = requirementsByKey.values.toList(growable: false)
      ..sort((left, right) => left.stableKey.compareTo(right.stableKey));

    return WorkshopModuleAssemblyPlan(
      projectId: reusePlan.projectId,
      generatedAt: reusePlan.generatedAt,
      pins: List<String>.unmodifiable(pins),
      changes: List<WorkspaceFileChange>.unmodifiable(changes),
      requirements: List<WorkshopAssemblyRequirement>.unmodifiable(requirements),
      conflicts: List<WorkshopAssemblyConflict>.unmodifiable(conflicts),
      identicalExistingPaths: List<String>.unmodifiable(identical),
    );
  }

  static int _compareConflict(
    WorkshopAssemblyConflict left,
    WorkshopAssemblyConflict right,
  ) {
    var value = left.pin.compareTo(right.pin);
    if (value != 0) return value;
    value = (left.path ?? '').compareTo(right.path ?? '');
    if (value != 0) return value;
    return left.kind.name.compareTo(right.kind.name);
  }

  static bool _isSafeTargetPath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
      return false;
    }

    final segments = path.split('/');
    if (segments.any((segment) => segment.isEmpty || segment == '..' || segment == '.')) {
      return false;
    }

    final lowerSegments = segments.map((segment) => segment.toLowerCase()).toList();
    if (lowerSegments.any(
      (segment) => const <String>{
        '.git',
        '.dart_tool',
        'build',
        'node_modules',
      }.contains(segment),
    )) {
      return false;
    }

    final fileName = lowerSegments.last;
    if (fileName == '.env' ||
        fileName == 'key.properties' ||
        fileName.endsWith('.jks') ||
        fileName.endsWith('.keystore') ||
        fileName.endsWith('.p12') ||
        fileName.endsWith('.pfx') ||
        fileName.endsWith('.pem') ||
        fileName.endsWith('.key')) {
      return false;
    }

    return true;
  }
}
