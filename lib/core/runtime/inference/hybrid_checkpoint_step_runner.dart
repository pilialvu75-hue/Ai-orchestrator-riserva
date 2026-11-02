import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/stream_text_accumulator.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

/// A single model call for one explicitly planned HYBRID checkpoint.
///
/// This is an opt-in integration boundary: callers connect it to the existing
/// DirectiveAwareInferenceService.stream and supply an already authorized,
/// user-owned execution plan. It does NOT run in ordinary Chat by default.
///
/// No Cloud call is made unless the current spending policy recommends a
/// provider AND the caller explicitly approves the exact outbound text.
/// Every step is validated by an independent caller-supplied gate before
/// becoming a checkpoint. Network failure never causes a silent replay.
final class HybridCheckpointStepRunner {
  HybridCheckpointStepRunner({
    required HybridCheckpointSnapshotStore snapshotStore,
    required CloudRuntimeProvider cloudRuntimeProvider,
    required TokenStream Function(InferenceRequest) streamInference,
  })  : _store = snapshotStore,
        _cloud = cloudRuntimeProvider,
        _stream = streamInference;

  static const int maxResumeCharacters = 16 * 1024;

  final HybridCheckpointSnapshotStore _store;
  final CloudRuntimeProvider _cloud;
  final TokenStream Function(InferenceRequest) _stream;

  /// Executes exactly one checkpoint; the caller keeps ownership of planning,
  /// session/owner identification, network state, and the next Attempt.
  ///
  /// [authorizeCloudText] is mandatory for Cloud and receives the ENTIRE
  /// outbound prompt, including prior explicit results. The caller must
  /// implement owner authorization, privacy classification and consent.
  /// This component deliberately never copies request history, private memory
  /// or system prompts into an outgoing Cloud request.
  ///
  /// [validateResult] is mandatory for both routes. Generated text is merely
  /// proposed until an external gate verifies it.
  Future<String> executeNext({
    required String ownerId,
    required HybridCheckpointLedger ledger,
    required HybridAttemptLease lease,
    required String sessionId,
    required String stepInstruction,
    required bool isOffline,
    required Future<bool> Function(String result) validateResult,
    Future<bool> Function(String outboundText)? authorizeCloudText,
  }) async {
    if (sessionId.trim().isEmpty || stepInstruction.trim().isEmpty) {
      throw ArgumentError('A session and a planned checkpoint are required');
    }
    if (ledger.isComplete) {
      throw StateError('HYBRID execution is already complete');
    }

    final step = ledger.nextCheckpoint;
    final resume = ledger.completed.map((completed) =>
        'Checkpoint ${completed.number} completed by '
        '${completed.executor.name}: ${completed.result}').join('\n');
    if (resume.length > maxResumeCharacters) {
      throw StateError('Verified resume context exceeds the safe bound');
    }
    final prompt = 'Execution checkpoint $step of '
        '${ledger.totalCheckpoints}.\n'
        'Previously completed steps (explicit received results):\n'
        '${resume.isEmpty ? "(none)" : resume}\n'
        'Do only the current step and report its explicit result.\n'
        'Current step: $stepInstruction';
    if (prompt.length > maxResumeCharacters * 2) {
      throw StateError('HYBRID step prompt exceeds the safe bound');
    }

    String? approvedCloudProvider;
    if (lease.executor == HybridCheckpointExecutor.cloud) {
      if (isOffline || authorizeCloudText == null) {
        throw StateError('Offline or unconsented HYBRID Cloud execution');
      }
      // The Cloud recommendation is task-aware and enforces AUTO opt-in and
      // spending restrictions, unlike a manually pinned cloudOnly request.
      final preflight = InferenceRequest(
        sessionId: sessionId,
        prompt: prompt,
        routeDirective: InferenceRouteDirective.runtimeDefault,
      );
      approvedCloudProvider = _cloud.recommendProviderFor(
        preflight,
        enforceAutomaticPolicy: true,
      );
      if (approvedCloudProvider == null ||
          !await authorizeCloudText(prompt)) {
        throw StateError('HYBRID Cloud route is not authorized or available');
      }
    }

    // Construct a fresh request to avoid forwarding hidden private memory,
    // unrelated context or a stale provider binding from another operation.
    final request = InferenceRequest(
      sessionId: sessionId,
      prompt: prompt,
      isOffline: isOffline,
      allowWebSearchTool: false,
      requestId: '${ledger.executionId}-$step',
      executionId: ledger.executionId,
      attemptId: lease.attemptId,
      checkpointId: 'checkpoint-$step',
      routeDirective: lease.executor == HybridCheckpointExecutor.local
          ? InferenceRouteDirective.localOnly
          : InferenceRouteDirective.cloudOnly,
      cloudProviderId: approvedCloudProvider,
      allowCloudProviderFailover: false,
      requireAutomaticCloudPolicy:
          lease.executor == HybridCheckpointExecutor.cloud,
    );

    final assigned = ledger.startCheckpoint(lease);
    if (assigned != step) {
      throw StateError('HYBRID checkpoint assignment changed');
    }
    try {
      var output = '';
      var sawSuccess = false;
      await for (final chunk in _stream(request)) {
        if (chunk.runtimeNotice != null) continue;
        if (chunk.isError ||
            (chunk.isFinal &&
                chunk.terminalState != InferenceTerminalState.success)) {
          throw StateError('HYBRID inference did not complete successfully');
        }
        if (chunk.text.isNotEmpty) {
          output = mergeStreamedText(
            currentText: output,
            incomingText: chunk.text,
            isFinalChunk: chunk.isFinal,
          );
        }
        if (chunk.isFinal) {
          sawSuccess = true;
        }
      }
      if (!sawSuccess || output.trim().isEmpty) {
        throw StateError('HYBRID checkpoint has no confirmed final result');
      }
      if (!await validateResult(output)) {
        throw StateError('HYBRID checkpoint was not independently validated');
      }
      await ledger.completeCheckpointDurably(
        lease: lease,
        checkpoint: step,
        result: output,
        persist: (snapshot) => _store.saveSnapshot(
          ownerId: ownerId,
          snapshot: snapshot,
        ),
      );
      return output;
    } catch (_) {
      // The protected store, not this object, is authoritative on retry.
      // A write may have succeeded before a readback failed. The caller must
      // reload from the protected store before assigning a new Attempt.
      ledger.interruptAttempt(lease);
      rethrow;
    }
  }
}
