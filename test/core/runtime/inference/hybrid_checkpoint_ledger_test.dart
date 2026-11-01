import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void finish(
    HybridCheckpointLedger ledger,
    HybridAttemptLease lease,
    int expected,
  ) {
    expect(ledger.startCheckpoint(lease), expected);
    ledger.completeCheckpoint(
      lease: lease,
      checkpoint: expected,
      result: 'Verified result for step $expected',
    );
  }

  group('HYBRID checkpoint continuity: 10-step gallery scenario', () {
    test('3 Cloud + 4 Local; reconnection does not force Cloud handback',
        () {
      final ledger = HybridCheckpointLedger(
        executionId: 'gallery-10',
        totalCheckpoints: 10,
      );
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      for (var step = 1; step <= 3; step++) {
        finish(ledger, cloud, step);
      }

      // Device enters gallery and loses network.
      ledger.interruptAttempt(cloud);
      final local = ledger.beginAttempt(
        attemptId: 'local-2',
        executor: HybridCheckpointExecutor.local,
      );
      for (var step = 4; step <= 7; step++) {
        finish(ledger, local, step);
      }

      // Network returns: no implicit mutation of the active Attempt.
      expect(ledger.completedCount, 7);
      expect(ledger.nextCheckpoint, 8);
      expect(ledger.completed.where((step) =>
          step.executor == HybridCheckpointExecutor.cloud), hasLength(3));
      expect(ledger.completed.where((step) =>
          step.executor == HybridCheckpointExecutor.local), hasLength(4));

      for (var step = 8; step <= 10; step++) {
        finish(ledger, local, step);
      }
      expect(ledger.isComplete, isTrue);
      expect(ledger.completed.map((step) => step.number),
          orderedEquals(List<int>.generate(10, (i) => i + 1)));
      expect(
        () => ledger.startCheckpoint(local),
        throwsStateError,
      );
    });

    test('handback is allowed only between completed checkpoints', () {
      final ledger =
          HybridCheckpointLedger(executionId: 'handoff', totalCheckpoints: 10);
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      for (var i = 1; i <= 3; i++) {
        finish(ledger, cloud, i);
      }
      ledger.interruptAttempt(cloud);
      final local = ledger.beginAttempt(
        attemptId: 'local-2',
        executor: HybridCheckpointExecutor.local,
      );
      for (var i = 4; i <= 7; i++) {
        finish(ledger, local, i);
      }

      expect(ledger.startCheckpoint(local), 8);
      expect(
        () => ledger.beginAttempt(
          attemptId: 'cloud-3',
          executor: HybridCheckpointExecutor.cloud,
        ),
        throwsStateError,
      );
      ledger.completeCheckpoint(
        lease: local,
        checkpoint: 8,
        result: 'Local step 8 is complete',
      );

      final resumedCloud = ledger.beginAttempt(
        attemptId: 'cloud-3',
        executor: HybridCheckpointExecutor.cloud,
      );
      expect(() => ledger.startCheckpoint(local), throwsStateError);
      finish(ledger, resumedCloud, 9);
      finish(ledger, resumedCloud, 10);

      expect(ledger.isComplete, isTrue);
      expect(ledger.completed[7].executor, HybridCheckpointExecutor.local);
      expect(ledger.completed[8].executor, HybridCheckpointExecutor.cloud);
      expect(ledger.completed[9].executor, HybridCheckpointExecutor.cloud);
    });

    test('unreturned Cloud output is never promoted to a checkpoint', () {
      final ledger =
          HybridCheckpointLedger(executionId: 'interrupted', totalCheckpoints: 4);
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      finish(ledger, cloud, 1);

      expect(ledger.startCheckpoint(cloud), 2);
      // Some stream tokens arrived, but no final validated checkpoint exists.
      final persisted = jsonDecode(jsonEncode(ledger.toJson()))
          as Map<String, dynamic>;
      expect(persisted['completed'], hasLength(1));

      ledger.interruptAttempt(cloud);
      expect(
        () => ledger.completeCheckpoint(
          lease: cloud,
          checkpoint: 2,
          result: 'Late Cloud callback after network loss',
        ),
        throwsStateError,
      );

      // A process restart or new device must begin a new Attempt.
      final restored = HybridCheckpointLedger.fromJson(persisted);
      expect(restored.completedCount, 1);
      expect(restored.inFlightCheckpoint, isNull);
      final local = restored.beginAttempt(
        attemptId: 'local-2',
        executor: HybridCheckpointExecutor.local,
      );
      finish(restored, local, 2);
      expect(restored.completed.map((step) => step.number), [1, 2]);
      expect(restored.completed.last.result, 'Verified result for step 2');
    });

    test('stale attempt cannot double-complete an already committed step', () {
      final ledger =
          HybridCheckpointLedger(executionId: 'fencing', totalCheckpoints: 3);
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      finish(ledger, cloud, 1);
      expect(
        () => ledger.completeCheckpoint(
          lease: cloud,
          checkpoint: 1,
          result: 'duplicate',
        ),
        throwsStateError,
      );

      final local = ledger.beginAttempt(
        attemptId: 'local-2',
        executor: HybridCheckpointExecutor.local,
      );
      expect(() => ledger.startCheckpoint(cloud), throwsStateError);
      finish(ledger, local, 2);
      expect(ledger.completedCount, 2);
    });

    test('corrupted snapshots fail closed instead of skipping work', () {
      final ledger =
          HybridCheckpointLedger(executionId: 'check', totalCheckpoints: 3);
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      finish(ledger, cloud, 1);
      final good = ledger.toJson();
      final corrupt = Map<String, Object?>.from(good);
      corrupt['completed'] = <Map<String, Object?>>[
        <String, Object?>{
          'number': 2, // Step 1 has disappeared.
          'attemptId': 'cloud-1',
          'executor': 'cloud',
          'result': 'result without preceding checkpoint',
        },
      ];
      expect(
        () => HybridCheckpointLedger.fromJson(
          Map<String, dynamic>.from(corrupt),
        ),
        throwsFormatException,
      );
      expect(
        () => HybridCheckpointLedger.fromJson(
          <String, dynamic>{...good, 'schemaVersion': 999},
        ),
        throwsFormatException,
      );
    });

    test('blank/unreceived results cannot advance progress', () {
      final ledger =
          HybridCheckpointLedger(executionId: 'missing', totalCheckpoints: 2);
      final cloud = ledger.beginAttempt(
        attemptId: 'cloud-1',
        executor: HybridCheckpointExecutor.cloud,
      );
      final checkpoint = ledger.startCheckpoint(cloud);
      expect(
        () => ledger.completeCheckpoint(
          lease: cloud,
          checkpoint: checkpoint,
          result: ' ',
        ),
        throwsArgumentError,
      );
      expect(ledger.completedCount, 0);
      expect(ledger.inFlightCheckpoint, 1);
      ledger.interruptAttempt(cloud);
      expect(ledger.nextCheckpoint, 1);
    });
  });
}
