/// Provider-neutral, in-memory checkpoint contract for Assistant HYBRID.
///
/// An Execution owns the logical work. An Attempt (Cloud or Local) only owns
/// the current step while its lease is valid. A network reconnect does not
/// implicitly transfer that lease. No provider is called by this component.
///
/// This is a H1 foundation, NOT durable recovery by itself. A production
/// adapter must atomically persist each committed snapshot to an owner-scoped,
/// protected store and verify that write before advancing execution. Snapshots
/// may contain user content: NEVER store them in plaintext preferences,
/// Diagnostics logs, or an unconsented Cloud service.
///
/// Only explicit, received results are committed. Private chain-of-thought
/// and unreturned Cloud output cannot be checkpointed.
enum HybridCheckpointExecutor { local, cloud }

/// A single validated checkpoint, not an in-progress token stream.
final class HybridCompletedCheckpoint {
  const HybridCompletedCheckpoint({
    required this.number,
    required this.attemptId,
    required this.executor,
    required this.result,
  });

  final int number;
  final String attemptId;
  final HybridCheckpointExecutor executor;

  /// Explicit output received from the executor, not hidden reasoning.
  final String result;

  Map<String, Object?> toJson() => <String, Object?>{
        'number': number,
        'attemptId': attemptId,
        'executor': executor.name,
        'result': result,
      };

  static HybridCompletedCheckpoint fromJson(Map<String, dynamic> json) {
    final number = json['number'];
    final attemptId = json['attemptId'];
    final executorName = json['executor'];
    final result = json['result'];
    if (number is! int ||
        number <= 0 ||
        attemptId is! String ||
        attemptId.trim().isEmpty ||
        executorName is! String ||
        result is! String ||
        result.trim().isEmpty) {
      throw const FormatException('Invalid HYBRID checkpoint');
    }

    HybridCheckpointExecutor? executor;
    for (final value in HybridCheckpointExecutor.values) {
      if (value.name == executorName) {
        executor = value;
        break;
      }
    }
    if (executor == null) {
      throw const FormatException('Unknown HYBRID executor');
    }
    return HybridCompletedCheckpoint(
      number: number,
      attemptId: attemptId,
      executor: executor,
      result: result,
    );
  }
}

/// A fencing capability bound to one ledger instance and one Attempt.
/// A stale Cloud callback cannot commit after Local takes ownership.
final class HybridAttemptLease {
  HybridAttemptLease._({
    required this.attemptId,
    required this.executor,
    required this.generation,
  });

  final String attemptId;
  final HybridCheckpointExecutor executor;
  final int generation;
}

/// Tracks a single logical Assistant operation without starting any inference.
///
/// The caller must save a snapshot to protected durable storage after a
/// checkpoint is committed. In-flight tokens are intentionally excluded from
/// snapshots: on recovery the next unfinished checkpoint is retried, not
/// incorrectly counted as completed.
final class HybridCheckpointLedger {
  HybridCheckpointLedger({
    required this.executionId,
    required this.totalCheckpoints,
  }) {
    if (executionId.trim().isEmpty ||
        totalCheckpoints <= 0 ||
        totalCheckpoints > 10000) {
      throw ArgumentError('Invalid HYBRID execution identity or size');
    }
  }

  HybridCheckpointLedger._restored({
    required this.executionId,
    required this.totalCheckpoints,
    required List<HybridCompletedCheckpoint> completed,
    required int generation,
  })  : _completed = completed,
        _generation = generation;

  static const int schemaVersion = 1;
  final String executionId;
  final int totalCheckpoints;
  final List<HybridCompletedCheckpoint> _completed =
      <HybridCompletedCheckpoint>[];

  int _generation = 0;
  HybridAttemptLease? _activeLease;
  int? _inFlightCheckpoint;

  int get completedCount => _completed.length;
  int? get inFlightCheckpoint => _inFlightCheckpoint;
  int get nextCheckpoint => completedCount + 1;
  bool get isComplete => completedCount == totalCheckpoints;

  List<HybridCompletedCheckpoint> get completed =>
      List<HybridCompletedCheckpoint>.unmodifiable(_completed);

  /// Assigns the next segment at a checkpoint boundary. Reconnection alone
  /// never calls this; a higher-level policy decides whether handback helps.
  HybridAttemptLease beginAttempt({
    required String attemptId,
    required HybridCheckpointExecutor executor,
  }) {
    if (attemptId.trim().isEmpty) {
      throw ArgumentError.value(attemptId, 'attemptId');
    }
    if (_inFlightCheckpoint != null || isComplete) {
      throw StateError('Cannot switch executor during a checkpoint or after completion');
    }
    if (_activeLease?.attemptId == attemptId) {
      throw StateError('A handoff needs a distinct attempt identity');
    }
    final lease = HybridAttemptLease._(
      attemptId: attemptId,
      executor: executor,
      generation: ++_generation,
    );
    _activeLease = lease;
    return lease;
  }

  int startCheckpoint(HybridAttemptLease lease) {
    _requireActive(lease);
    if (isComplete || _inFlightCheckpoint != null) {
      throw StateError('Checkpoint already running or work already complete');
    }
    return _inFlightCheckpoint = nextCheckpoint;
  }

  /// Commits exactly one completed step; duplicate/out-of-order/stale results
  /// cannot be marked as completed. The result must have been received.
  ///
  /// The persistence adapter still needs to atomically save [toJson] before
  /// treating this commit as durable or reporting its progress to the UI.
  void completeCheckpoint({
    required HybridAttemptLease lease,
    required int checkpoint,
    required String result,
  }) {
    _requireActive(lease);
    if (_inFlightCheckpoint != checkpoint || checkpoint != nextCheckpoint) {
      throw StateError('Checkpoint is not the one currently assigned');
    }
    if (result.trim().isEmpty) {
      throw ArgumentError.value(result, 'result', 'No received result');
    }
    _completed.add(
      HybridCompletedCheckpoint(
        number: checkpoint,
        attemptId: lease.attemptId,
        executor: lease.executor,
        result: result,
      ),
    );
    _inFlightCheckpoint = null;
  }

  /// Network loss or cancellation fences off the old executor. Any unfinished
  /// step is discarded, and only the last committed checkpoint is retained.
  void interruptAttempt(HybridAttemptLease lease) {
    _requireActive(lease);
    _inFlightCheckpoint = null;
    _activeLease = null;
    ++_generation;
  }

  void _requireActive(HybridAttemptLease lease) {
    if (!identical(_activeLease, lease) ||
        lease.generation != _generation) {
      throw StateError('Stale or unowned HYBRID attempt');
    }
  }

  /// Explicit results are sensitive user-owned content. Persist only through
  /// a protected, owner-scoped adapter. Never log or upload this snapshot.
  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'executionId': executionId,
        'totalCheckpoints': totalCheckpoints,
        'generation': _generation,
        'completed': _completed
            .map((checkpoint) => checkpoint.toJson())
            .toList(growable: false),
      };

  /// Restores only received, completed steps. It intentionally restores with
  /// no active Attempt/lease, so a new Local or Cloud Attempt must be assigned
  /// by the orchestrator after verifying permissions and model readiness.
  factory HybridCheckpointLedger.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    final id = json['executionId'];
    final total = json['totalCheckpoints'];
    final generation = json['generation'];
    final rawSteps = json['completed'];
    if (version != schemaVersion ||
        id is! String ||
        id.trim().isEmpty ||
        total is! int ||
        total <= 0 ||
        total > 10000 ||
        generation is! int ||
        generation < 0 ||
        rawSteps is! List ||
        rawSteps.length > total) {
      throw const FormatException('Invalid HYBRID execution snapshot');
    }

    final restored = <HybridCompletedCheckpoint>[];
    for (final raw in rawSteps) {
      if (raw is! Map) {
        throw const FormatException('Invalid HYBRID checkpoint record');
      }
      final step = HybridCompletedCheckpoint.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (step.number != restored.length + 1) {
        throw const FormatException('Noncontiguous HYBRID checkpoints');
      }
      restored.add(step);
    }
    return HybridCheckpointLedger._restored(
      executionId: id,
      totalCheckpoints: total,
      completed: restored,
      generation: generation + 1,
    );
  }
}
