import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_certified_library_evidence.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_read_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_remote_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

final class WorkshopLibraryReuseResult {
  const WorkshopLibraryReuseResult({
    required this.attempted,
    required this.reusedPins,
    required this.stagedPaths,
    this.reuseIdentity,
    this.evidence,
    this.reason,
  });

  final bool attempted;
  final List<String> reusedPins;
  final List<String> stagedPaths;

  /// Deterministic identity of the verified remote export actually selected
  /// for reuse. It binds the snapshot SHA, exact pins and package-envelope
  /// digests so preflight resume cannot silently reuse a plan for different
  /// certified Library bytes.
  final String? reuseIdentity;

  /// Verified read-only provenance and integration evidence for the exact
  /// certified bytes selected by this attempt.
  final WorkshopCertifiedLibraryEvidencePack? evidence;

  final String? reason;

  bool get staged => stagedPaths.isNotEmpty;

  /// True when the certified remote Library was selected successfully for the
  /// prepared project, including idempotent resume cases where every package
  /// file is already present with identical content and no new path is staged.
  bool get reused =>
      reusedPins.isNotEmpty &&
      evidence != null &&
      reuseIdentity != null &&
      reuseIdentity!.isNotEmpty &&
      evidence!.reuseIdentity == reuseIdentity &&
      reason == null;
}

/// Production bridge from an approved Cantiere plan to certified Module Library
/// packages. It is deliberately best-effort: a missing/offline Library or any
/// integrity/conflict condition falls back to the normal local/AI path.
///
/// Safe automatic file reuse remains addition-only and conflict-free. Required
/// dependency/configuration/native adaptation is preserved as certified
/// evidence for Architect/Engineer and stays inside the normal
/// Reviewer -> validation -> owner approval -> guarded apply lifecycle.
final class WorkshopLibraryReuseService {
  const WorkshopLibraryReuseService({
    required this.client,
    this.shoppingListBuilder = const WorkshopCapabilityShoppingListBuilder(),
    this.reusePlanner = const WorkshopCapabilityReusePlanner(),
    this.assemblyPlanner = const WorkshopModuleAssemblyPlanner(),
  });

  final WorkshopLibraryReadClient client;
  final WorkshopCapabilityShoppingListBuilder shoppingListBuilder;
  final WorkshopCapabilityReusePlanner reusePlanner;
  final WorkshopModuleAssemblyPlanner assemblyPlanner;

  Future<WorkshopLibraryReuseResult> stageForPreparedTask({
    required WorkshopProjectPlan plan,
    required WorkspaceSession session,
    required WorkshopProjectApprovalEvidence approval,
  }) async {
    final shoppingList = shoppingListBuilder.build(
      plan: plan,
      approval: approval,
    );
    if (shoppingList.isEmpty) {
      return const WorkshopLibraryReuseResult(
        attempted: false,
        reusedPins: <String>[],
        stagedPaths: <String>[],
        reason: 'no-mapped-capability-needs',
      );
    }

    try {
      final remote = await client.loadState();
      final reusePlan = reusePlanner.plan(
        shoppingList: shoppingList,
        candidates: remote.snapshot.candidates,
      );
      final reuseDecisions = reusePlan.decisions
          .where((item) => item.action == WorkshopCapabilityReuseAction.reuse)
          .toList(growable: false);
      if (reuseDecisions.isEmpty) {
        return const WorkshopLibraryReuseResult(
          attempted: true,
          reusedPins: <String>[],
          stagedPaths: <String>[],
          reason: 'no-economic-certified-reuse',
        );
      }

      final packages = <String, WorkshopReusableModulePackage>{};
      for (final decision in reuseDecisions) {
        final pin = decision.candidate?.pin;
        if (pin == null || pin.isEmpty || packages.containsKey(pin)) continue;
        packages[pin] = await client.loadPackage(state: remote, pin: pin);
      }

      final assembly = assemblyPlanner.plan(
        reusePlan: reusePlan,
        packagesByPin: packages,
        workspaceSnapshot: session.workspace.snapshot,
      );

      if (assembly.hasBlockingConflicts) {
        return WorkshopLibraryReuseResult(
          attempted: true,
          reusedPins: List<String>.unmodifiable(assembly.pins),
          stagedPaths: const <String>[],
          reason: 'assembly-conflict',
        );
      }

      final staged = <String>[];
      for (final change in assembly.changes) {
        if (!change.isAddition || change.afterContent == null) {
          return WorkshopLibraryReuseResult(
            attempted: true,
            reusedPins: List<String>.unmodifiable(assembly.pins),
            stagedPaths: const <String>[],
            reason: 'unsafe-non-additive-assembly',
          );
        }
        staged.add(change.path);
      }
      staged.sort();

      final evidence = _buildEvidence(
        remote: remote,
        reuseDecisions: reuseDecisions,
        packages: packages,
        assembly: assembly,
        stagedPaths: staged,
      );

      final written = <String>[];
      try {
        for (final change in assembly.changes) {
          session.workspace.write(
            path: change.path,
            content: change.afterContent!,
          );
          written.add(change.path);
        }
      } catch (_) {
        for (final path in written.reversed) {
          session.workspace.revert(path);
        }
        rethrow;
      }

      return WorkshopLibraryReuseResult(
        attempted: true,
        reusedPins: List<String>.unmodifiable(assembly.pins),
        stagedPaths: List<String>.unmodifiable(staged),
        reuseIdentity: evidence.reuseIdentity,
        evidence: evidence,
      );
    } catch (_) {
      return const WorkshopLibraryReuseResult(
        attempted: true,
        reusedPins: <String>[],
        stagedPaths: <String>[],
        reason: 'library-unavailable-or-unverified',
      );
    }
  }

  WorkshopCertifiedLibraryEvidencePack _buildEvidence({
    required WorkshopLibraryRemoteState remote,
    required List<WorkshopCapabilityReuseDecision> reuseDecisions,
    required Map<String, WorkshopReusableModulePackage> packages,
    required WorkshopModuleAssemblyPlan assembly,
    required List<String> stagedPaths,
  }) {
    final reuseIdentity = _verifiedReuseIdentity(
      remote: remote,
      pins: assembly.pins,
    );

    final selections = <WorkshopCertifiedLibrarySelectionEvidence>[];
    for (final decision in reuseDecisions) {
      final candidate = decision.candidate;
      if (candidate == null || candidate.pin.trim().isEmpty) {
        throw StateError(
          'Certified reuse decision is missing its exact selected pin.',
        );
      }
      final targets = decision.need.targets.toSet().toList(growable: false)
        ..sort();
      selections.add(
        WorkshopCertifiedLibrarySelectionEvidence(
          pin: candidate.pin,
          capabilityId: decision.need.capabilityId,
          contractId: decision.need.preferredContractId,
          targets: List<String>.unmodifiable(targets),
        ),
      );
    }
    selections.sort((left, right) {
      var value = left.capabilityId.compareTo(right.capabilityId);
      if (value != 0) return value;
      value = left.contractId.compareTo(right.contractId);
      if (value != 0) return value;
      return left.pin.compareTo(right.pin);
    });

    final assets = <WorkshopCertifiedLibraryAssetEvidence>[];
    final pins = assembly.pins.toSet().toList(growable: false)..sort();
    for (final pin in pins) {
      final snapshotAsset = remote.snapshot.assetByPin(pin);
      final indexEntry = remote.packageIndex[pin];
      final package = packages[pin];
      if (snapshotAsset == null || indexEntry == null || package == null) {
        throw StateError(
          'Certified reuse evidence is incomplete for selected pin "' +
              pin +
              '".',
        );
      }
      if (package.pin != pin ||
          package.manifestDigest != snapshotAsset.manifestSha256 ||
          package.artifactDigest != snapshotAsset.moduleTreeSha256 ||
          indexEntry.moduleTreeSha256 != snapshotAsset.moduleTreeSha256) {
        throw StateError(
          'Certified reuse package no longer matches verified snapshot "' +
              pin +
              '".',
        );
      }

      final candidate = snapshotAsset.candidate;
      final capabilities =
          candidate.capabilities.toSet().toList(growable: false)..sort();
      final contracts =
          candidate.contracts.toSet().toList(growable: false)..sort();
      final targets = candidate.targets.toSet().toList(growable: false)..sort();

      assets.add(
        WorkshopCertifiedLibraryAssetEvidence(
          pin: pin,
          manifestSha256: snapshotAsset.manifestSha256,
          moduleTreeSha256: snapshotAsset.moduleTreeSha256,
          packageSha256: indexEntry.packageSha256,
          validationScore: candidate.validationScore,
          capabilities: List<String>.unmodifiable(capabilities),
          contracts: List<String>.unmodifiable(contracts),
          targets: List<String>.unmodifiable(targets),
        ),
      );
    }

    final requirements = assembly.requirements
        .map(
          (item) => WorkshopCertifiedLibraryRequirementEvidence(
            kind: item.kind.name,
            description: item.description.trim(),
            required: item.required,
          ),
        )
        .toList(growable: false)
      ..sort((left, right) {
        var value = left.kind.compareTo(right.kind);
        if (value != 0) return value;
        value = left.required == right.required
            ? 0
            : left.required
                ? -1
                : 1;
        if (value != 0) return value;
        return left.description.compareTo(right.description);
      });

    final identical =
        assembly.identicalExistingPaths.toSet().toList(growable: false)
          ..sort();

    return WorkshopCertifiedLibraryEvidencePack(
      libraryId: remote.snapshot.libraryId,
      catalogVersion: remote.snapshot.catalogVersion,
      snapshotSha256: remote.snapshot.snapshotSha256,
      reuseIdentity: reuseIdentity,
      disposition: assembly.requiresAdaptation
          ? WorkshopCertifiedLibraryEvidenceDisposition.adaptationRequired
          : WorkshopCertifiedLibraryEvidenceDisposition.staged,
      selections:
          List<WorkshopCertifiedLibrarySelectionEvidence>.unmodifiable(
        selections,
      ),
      assets: List<WorkshopCertifiedLibraryAssetEvidence>.unmodifiable(assets),
      requirements:
          List<WorkshopCertifiedLibraryRequirementEvidence>.unmodifiable(
        requirements,
      ),
      stagedPaths: List<String>.unmodifiable(stagedPaths),
      identicalExistingPaths: List<String>.unmodifiable(identical),
    );
  }

  String _verifiedReuseIdentity({
    required WorkshopLibraryRemoteState remote,
    required List<String> pins,
  }) {
    final sortedPins = pins.toSet().toList(growable: false)..sort();
    final components = <String>[
      remote.snapshot.snapshotSha256,
      for (final pin in sortedPins)
        '$pin:${remote.packageIndex[pin]?.packageSha256 ?? ''}',
    ];
    return components.join('|');
  }
}
