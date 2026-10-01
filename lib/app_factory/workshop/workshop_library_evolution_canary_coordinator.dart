import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_claim_adapter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_inference_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_research_library_handoff.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Canary-only coordinator for the first real Library Evolution path.
///
/// Deliberately fail-closed: until the acceleration backend canary proves the
/// complete claim -> inference -> validated Library intake path, no other
/// capability is allowed through this coordinator.
final class WorkshopLibraryEvolutionCanaryCoordinator {
  const WorkshopLibraryEvolutionCanaryCoordinator({
    required WorkshopLibraryEvolutionInferenceRunner inferenceRunner,
    required WorkshopResearchLibraryHandoff libraryHandoff,
    this.claimAdapter = const WorkshopLibraryEvolutionClaimAdapter(),
  })  : _inferenceRunner = inferenceRunner,
        _libraryHandoff = libraryHandoff;

  static const String canaryCapability = 'ai.acceleration_backend';

  final WorkshopLibraryEvolutionClaimAdapter claimAdapter;
  final WorkshopLibraryEvolutionInferenceRunner _inferenceRunner;
  final WorkshopResearchLibraryHandoff _libraryHandoff;

  Future<WorkshopLibrarySubmissionResult> run({
    required Map<String, dynamic> claim,
    required GitWorkspaceGateway gateway,
    required WorkshopLibraryCaptureEvidence evidence,
    bool isOffline = false,
    CancellationToken? cancellationToken,
  }) async {
    final capability = claim['capability_id']?.toString().trim();
    if (capability != canaryCapability) {
      return WorkshopLibrarySubmissionResult.reject(
        const <String>['library-evolution-canary-capability-blocked'],
      );
    }

    final task = claimAdapter.fromJson(claim);
    final result = await _inferenceRunner.run(
      task: task,
      gateway: gateway,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    return _libraryHandoff.submitValidatedCandidate(
      task: task,
      result: result,
      evidence: evidence,
    );
  }
}
