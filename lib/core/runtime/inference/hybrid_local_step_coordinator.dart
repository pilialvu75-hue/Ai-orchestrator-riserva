import 'hybrid_progress_checkpoint_journal.dart';
import 'hybrid_protected_resume_adapter.dart';
import 'hybrid_semantic_step_evidence_store.dart';

/// A local model's explicit, completed and externally validated output.
/// A partial stream or hidden reasoning cannot be submitted as evidence.
typedef HybridLocalStepExecutor = Future<HybridVerifiedStepResult> Function(
  String instruction,
  List<String> verifiedPreviousResults,
);

/// H50: manual, opt-in LOCAL continuation of exactly one verified step.
/// This class never accesses a remote provider or initiates Web searches.
/// The caller must supply an already-configured LOCAL-only executor.
final class HybridLocalStepCoordinator {
  const HybridLocalStepCoordinator({
    required HybridProtectedResumeAdapter resume,
    required HybridProgressCheckpointJournal journal,
    required HybridSemanticStepEvidenceStore evidence,
  }) : _resume = resume, _journal = journal, _evidence = evidence;

  final HybridProtectedResumeAdapter _resume;
  final HybridProgressCheckpointJournal _journal;
  final HybridSemanticStepEvidenceStore _evidence;

  /// Does not auto-resume on app start or network recovery.
  /// Only a direct caller can launch a stage, with an explicit LOCAL executor.
  Future<HybridProgressCheckpoint> executeOneLocal({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required HybridLocalStepExecutor executeLocal,
    required Future<bool> Function(HybridVerifiedStepResult result)
        validateResult,
  }) async {
    final preview = await _resume.inspect(
      ownerId: ownerId,
      sessionId: sessionId,
      taskId: taskId,
    );
    final instruction = preview.nextInstruction;
    if (preview.isComplete || instruction == null) {
      throw StateError('No unfinished HYBRID step');
    }

    // Explicitly provided LOCAL execution. No Cloud SDK, dynamic provider
    // selection or automatic network retry exists in this coordinator.
    final candidate = await executeLocal(
      instruction,
      List<String>.unmodifiable(preview.verifiedResults),
    );
    if (candidate.output.trim().isEmpty ||
        candidate.provenance.trim().isEmpty ||
        !await validateResult(candidate)) {
      throw StateError('LOCAL result not verified');
    }

    // Detect progress changes during asynchronous LOCAL model inference.
    final current = await _journal.load(
      ownerId: ownerId, sessionId: sessionId, taskId: taskId,
    );
    if (current == null || current.revision != preview.revision ||
        current.completedSteps != preview.completedSteps) {
      throw StateError('HYBRID progress changed during LOCAL inference');
    }
    return _evidence.completeVerifiedStep(
      ownerId: ownerId,
      sessionId: sessionId,
      taskId: taskId,
      expectedRevision: preview.revision,
      executor: HybridCheckpointExecutor.local,
      result: candidate,
    );
  }
}
