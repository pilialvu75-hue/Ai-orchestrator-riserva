import 'hybrid_immutable_step_plan_store.dart';
import 'hybrid_progress_checkpoint_journal.dart';
import 'hybrid_resume_preflight.dart';
import 'hybrid_semantic_step_evidence_store.dart';

/// H49d: the ONLY production-facing read-only adapter for protected H49
/// plan/evidence stores. It does not route requests, resume execution,
/// request provider consent, or persist output.
final class HybridProtectedResumeAdapter {
  const HybridProtectedResumeAdapter({
    required HybridProgressCheckpointJournal journal,
    required HybridImmutableStepPlanStore plans,
    required HybridSemanticStepEvidenceStore evidence,
  })  : _journal = journal,
        _plans = plans,
        _evidence = evidence;

  final HybridProgressCheckpointJournal _journal;
  final HybridImmutableStepPlanStore _plans;
  final HybridSemanticStepEvidenceStore _evidence;

  /// Only an explicit validated receipt is eligible to become resume context.
  /// Unlike arbitrary callback-based previews, the source cannot be a caller-
  /// supplied string. Origin and integrity are validated by the secure store.
  Future<HybridResumePreview> inspect({
    required String ownerId,
    required String sessionId,
    required String taskId,
  }) {
    return HybridResumePreflight(
      journal: _journal,
      loadPlan: (owner, session, task) async {
        final plan = await _plans.load(
          ownerId: owner, sessionId: session, taskId: task);
        return plan?.steps;
      },
      loadEvidence: (owner, session, task, step) async {
        final receipt = await _evidence.loadCompletedStep(
          ownerId: owner,
          sessionId: session,
          taskId: task,
          step: step,
        );
        if (receipt == null || receipt.provenance.trim().isEmpty) {
          return null;
        }
        return receipt.output;
      },
    ).inspect(ownerId: ownerId, sessionId: sessionId, taskId: taskId);
  }
}
