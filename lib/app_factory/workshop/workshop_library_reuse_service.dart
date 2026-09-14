import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_read_client.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';

final class WorkshopLibraryReuseResult {
  const WorkshopLibraryReuseResult({
    required this.attempted,
    required this.reusedPins,
    required this.stagedPaths,
    this.reason,
  });

  final bool attempted;
  final List<String> reusedPins;
  final List<String> stagedPaths;
  final String? reason;

  bool get staged => stagedPaths.isNotEmpty;
}

/// Production bridge from an approved Cantiere plan to certified Module Library
/// packages. It is deliberately best-effort: a missing/offline Library or any
/// integrity/adaptation/conflict condition falls back to the normal AI path.
///
/// Safe automatic reuse is limited to addition-only, conflict-free packages
/// with no required adaptation work. Files are written only to VirtualWorkspace;
/// the existing Reviewer -> owner approval -> apply gates remain authoritative.
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

      if (assembly.hasBlockingConflicts || assembly.requiresAdaptation) {
        return WorkshopLibraryReuseResult(
          attempted: true,
          reusedPins: List<String>.unmodifiable(assembly.pins),
          stagedPaths: const <String>[],
          reason: assembly.hasBlockingConflicts
              ? 'assembly-conflict'
              : 'required-adaptation',
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
        session.workspace.write(
          path: change.path,
          content: change.afterContent!,
        );
        staged.add(change.path);
      }
      staged.sort();
      return WorkshopLibraryReuseResult(
        attempted: true,
        reusedPins: List<String>.unmodifiable(assembly.pins),
        stagedPaths: List<String>.unmodifiable(staged),
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
}
