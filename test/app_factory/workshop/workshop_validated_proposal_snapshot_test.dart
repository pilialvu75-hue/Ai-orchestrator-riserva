import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_change_proposal.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_review_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_proposal_validation_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_validated_proposal_snapshot.dart';

void main() {
  group('WorkshopValidatedProposalSnapshotService', () {
    late Directory root;
    late WorkshopValidatedProposalSnapshotService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'workshop-validated-proposal-',
      );
      service = WorkshopValidatedProposalSnapshotService(
        snapshotsRootPath: root.path,
      );
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('round-trips a validated proposal without granting apply approval',
        () async {
      final source = _validatedResult();
      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: source,
        baselineSnapshot: _baseline(),
      );

      expect(snapshot.executionId, 'execution-1');
      expect(snapshot.attemptId, 'attempt-1');
      expect(snapshot.requestId, 'request-1');
      expect(snapshot.manifestSha256, hasLength(64));
      expect(await File(p.join(snapshot.rootPath, 'snapshot.json')).exists(),
          isTrue);

      final restored = await service.restore(
          snapshot: snapshot,
          currentBaselineSnapshot: _baseline(),
        );

      expect(restored.readyForApproval, isTrue);
      expect(restored.review.approved, isTrue);
      expect(restored.review.summary, 'Review passed.');
      expect(restored.review.findings, <String>['No blocking issue.']);
      expect(restored.validation?.valid, isTrue);
      expect(restored.validation?.summary, 'Validation passed.');
      expect(restored.validation?.checks, <String>['analyze', 'test']);

      expect(
        restored.proposal.changes
            .map((change) => (change.path, change.type, change.afterContent))
            .toList(),
        <(String, WorkspaceChangeType, String?)>[
          ('lib/new.dart', WorkspaceChangeType.addition, 'void main() {}\n'),
          (
            'lib/existing.dart',
            WorkspaceChangeType.modification,
            'int answer = 42;\n'
          ),
          ('lib/old.dart', WorkspaceChangeType.deletion, null),
        ],
      );

      // Recovery reconstructs only the validated proposal/result. It has no
      // WorkspaceSession and therefore cannot approve or apply real changes.
      expect(restored.proposal.requestId, 'request-1');
    });

    test('descriptor round-trips through execution metadata', () async {
      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: _validatedResult(),
        baselineSnapshot: _baseline(),
      );

      final decoded =
          WorkshopValidatedProposalSnapshot.fromExecutionMetadata(
        snapshot.toExecutionMetadata(),
      );

      expect(decoded.executionId, snapshot.executionId);
      expect(decoded.attemptId, snapshot.attemptId);
      expect(decoded.projectId, snapshot.projectId);
      expect(decoded.taskId, snapshot.taskId);
      expect(decoded.requestId, snapshot.requestId);
      expect(decoded.rootPath, snapshot.rootPath);
      expect(decoded.manifestSha256, snapshot.manifestSha256);
      expect(decoded.createdAt, snapshot.createdAt);
    });

    test('tampered content is rejected by SHA-256 verification', () async {
      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: _validatedResult(),
        baselineSnapshot: _baseline(),
      );

      final target = File(
        p.join(snapshot.rootPath, 'files', 'lib', 'new.dart'),
      );
      await target.writeAsString('tampered\n', flush: true);

      await expectLater(
        service.restore(
          snapshot: snapshot,
          currentBaselineSnapshot: _baseline(),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('sensitive or excluded paths are rejected before capture', () async {
      final unsafe = WorkshopTaskInferenceResult(
        proposal: const WorkshopChangeProposal(
          requestId: 'request-1',
          explanation: 'Unsafe test proposal.',
          changes: <WorkspaceFileChange>[
            WorkspaceFileChange(
              path: '.env',
              type: WorkspaceChangeType.addition,
              afterContent: 'SECRET=value\n',
            ),
          ],
        ),
        review: const WorkshopReviewVerdict(
          approved: true,
          summary: 'Review passed.',
        ),
        validation: const WorkshopValidationVerdict(
          valid: true,
          summary: 'Validation passed.',
        ),
      );

      await expectLater(
        service.capture(
          executionId: 'execution-1',
          attemptId: 'attempt-1',
          projectId: 'project:request-1',
          taskId: 'task-1',
          result: unsafe,
          baselineSnapshot: _baseline(),
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        await root
            .list(recursive: true, followLinks: false)
            .where((entity) => entity is File)
            .toList(),
        isEmpty,
      );
    });

    test('changed live baseline blocks stale proposal recovery', () async {
      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: _validatedResult(),
        baselineSnapshot: _baseline(),
      );

      final changedBaseline = <String, String>{
        ..._baseline(),
        'lib/existing.dart': 'int answer = 7;\n',
      };

      await expectLater(
        service.restore(
          snapshot: snapshot,
          currentBaselineSnapshot: changedBaseline,
        ),
        throwsA(isA<WorkshopValidatedProposalBaselineConflict>()),
      );
    });

    test('symlinked snapshot content is rejected', () async {
      if (Platform.isWindows) return;

      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: _validatedResult(),
        baselineSnapshot: _baseline(),
      );

      final target = File(
        p.join(snapshot.rootPath, 'files', 'lib', 'new.dart'),
      );
      final outside = File(p.join(root.path, 'outside.dart'));
      await outside.writeAsString('outside\n', flush: true);
      await target.delete();
      await Link(target.path).create(outside.path);

      await expectLater(
        service.restore(
          snapshot: snapshot,
          currentBaselineSnapshot: _baseline(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('cleanup refuses a descriptor pointing at the configured root',
        () async {
      final forged = WorkshopValidatedProposalSnapshot(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        requestId: 'request-1',
        rootPath: root.path,
        manifestSha256: '0' * 64,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await expectLater(
        service.remove(forged),
        throwsA(isA<StateError>()),
      );
      expect(await root.exists(), isTrue);
    });

    test('manifest tampering is rejected before file restoration', () async {
      final snapshot = await service.capture(
        executionId: 'execution-1',
        attemptId: 'attempt-1',
        projectId: 'project:request-1',
        taskId: 'task-1',
        result: _validatedResult(),
        baselineSnapshot: _baseline(),
      );

      final manifest = File(p.join(snapshot.rootPath, 'snapshot.json'));
      final raw = await manifest.readAsString();
      await manifest.writeAsString(
        raw.replaceFirst('Validation passed.', 'Validation altered.'),
        flush: true,
      );

      await expectLater(
        service.restore(
          snapshot: snapshot,
          currentBaselineSnapshot: _baseline(),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Map<String, String> _baseline() => <String, String>{
      'lib/existing.dart': 'int answer = 0;\n',
      'lib/old.dart': 'legacy\n',
    };

WorkshopTaskInferenceResult _validatedResult() {
  return const WorkshopTaskInferenceResult(
    proposal: WorkshopChangeProposal(
      requestId: 'request-1',
      explanation: 'Validated changes.',
      changes: <WorkspaceFileChange>[
        WorkspaceFileChange(
          path: 'lib/new.dart',
          type: WorkspaceChangeType.addition,
          afterContent: 'void main() {}\n',
        ),
        WorkspaceFileChange(
          path: 'lib/existing.dart',
          type: WorkspaceChangeType.modification,
          beforeContent: 'int answer = 0;\n',
          afterContent: 'int answer = 42;\n',
        ),
        WorkspaceFileChange(
          path: 'lib/old.dart',
          type: WorkspaceChangeType.deletion,
          beforeContent: 'legacy\n',
        ),
      ],
    ),
    review: WorkshopReviewVerdict(
      approved: true,
      summary: 'Review passed.',
      findings: <String>['No blocking issue.'],
      warnings: <String>['Review warning.'],
    ),
    validation: WorkshopValidationVerdict(
      valid: true,
      summary: 'Validation passed.',
      checks: <String>['analyze', 'test'],
      warnings: <String>['Validation warning.'],
    ),
  );
}
