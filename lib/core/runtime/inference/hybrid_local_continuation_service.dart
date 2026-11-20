import 'hybrid_local_runtime_step_bridge.dart';
import 'hybrid_local_step_coordinator.dart';
import 'hybrid_progress_checkpoint_journal.dart';
import 'hybrid_semantic_step_evidence_store.dart';
import 'inference_service.dart';

/// H52: explicit entry point for exactly ONE protected LOCAL continuation.
///
/// Uses the same InferenceService as ordinary Chat, not an additional engine.
/// The caller must supply authorized protected stores and independently
/// validate the completed result. No automatic resume, remote call or Cloud
/// consent is granted here; Chat must invoke this only on a user action.
final class HybridLocalContinuationService {
  const HybridLocalContinuationService({
    required InferenceService inference,
    required HybridLocalStepCoordinator coordinator,
  }) : _inference = inference, _coordinator = coordinator;

  final InferenceService _inference;
  final HybridLocalStepCoordinator _coordinator;

  Future<HybridProgressCheckpoint> continueOneLocal({
    required String ownerId,
    required String sessionId,
    required String taskId,
    required Future<bool> Function(HybridVerifiedStepResult result)
        validateResult,
    int maxTokens = 512,
  }) {
    final bridge = HybridLocalRuntimeStepBridge(
      stream: _inference.stream,
      sessionId: sessionId,
      taskId: taskId,
      maxTokens: maxTokens,
    );
    return _coordinator.executeOneLocal(
      ownerId: ownerId,
      sessionId: sessionId,
      taskId: taskId,
      executeLocal: bridge.executeLocal,
      validateResult: validateResult,
    );
  }
}
