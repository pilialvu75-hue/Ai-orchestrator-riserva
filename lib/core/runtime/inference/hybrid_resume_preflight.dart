import 'dart:convert';

import 'hybrid_progress_checkpoint_journal.dart';

/// Read-only plan/result adapters. The concrete H49a/H49b protected stores
/// will be connected only after their own review and merge.
typedef HybridLoadStepInstructions = Future<List<String>?> Function(
    String ownerId, String sessionId, String taskId);
typedef HybridLoadStepEvidence = Future<String?> Function(
    String ownerId, String sessionId, String taskId, int oneBasedStep);

/// A verified snapshot for a *manual* continuation decision.
/// Constructing this object does not authorize any Cloud use.
final class HybridResumePreview {
  HybridResumePreview({
    required this.completedSteps,
    required this.totalSteps,
    required this.revision,
    required List<String> verifiedResults,
    required this.nextInstruction,
  }) : verifiedResults = List<String>.unmodifiable(verifiedResults);

  final int completedSteps;
  final int totalSteps;
  final int revision;
  final List<String> verifiedResults;
  final String? nextInstruction;
  bool get isComplete => completedSteps == totalSteps;
}

/// H49c preparation: fails closed when H48, an immutable plan, or any
/// completed-step receipt disagrees. No executor, HTTP, retry, or resume
/// is invoked here. This does NOT certify model answers as true.
final class HybridResumePreflight {
  const HybridResumePreflight({
    required HybridProgressCheckpointJournal journal,
    required HybridLoadStepInstructions loadPlan,
    required HybridLoadStepEvidence loadEvidence,
  }) : _journal = journal, _loadPlan = loadPlan,
       _loadEvidence = loadEvidence;

  final HybridProgressCheckpointJournal _journal;
  final HybridLoadStepInstructions _loadPlan;
  final HybridLoadStepEvidence _loadEvidence;

  Future<HybridResumePreview> inspect({
    required String ownerId,
    required String sessionId,
    required String taskId,
  }) async {
    final before = await _journal.load(
      ownerId: ownerId, sessionId: sessionId, taskId: taskId);
    if (before == null) {
      throw StateError('Missing or damaged HYBRID progress checkpoint');
    }
    final steps = await _loadPlan(ownerId, sessionId, taskId);
    if (steps == null || steps.length != before.totalSteps ||
        steps.any((s) => s.trim().isEmpty ||
            utf8.encode(s).length > 2048)) {
      throw StateError('Missing or mismatched immutable HYBRID plan');
    }

    final verified = <String>[];
    for (var n = 1; n <= before.completedSteps; n++) {
      final receipt = await _loadEvidence(ownerId, sessionId, taskId, n);
      if (receipt == null || receipt.trim().isEmpty ||
          utf8.encode(receipt).length > 8192) {
        throw StateError('Missing or damaged completed HYBRID step');
      }
      verified.add(receipt);
    }

    // Detect a concurrent step commit while checking multiple protected keys.
    // Without this second read, the preview could expose stale next-step data.
    final after = await _journal.load(
      ownerId: ownerId, sessionId: sessionId, taskId: taskId);
    if (after == null || before.revision != after.revision ||
        before.completedSteps != after.completedSteps ||
        before.totalSteps != after.totalSteps) {
      throw StateError('HYBRID progress changed during resume inspection');
    }
    return HybridResumePreview(
      completedSteps: before.completedSteps,
      totalSteps: before.totalSteps,
      revision: before.revision,
      verifiedResults: verified,
      nextInstruction: before.canContinue
          ? steps[before.completedSteps]
          : null,
    );
  }
}
