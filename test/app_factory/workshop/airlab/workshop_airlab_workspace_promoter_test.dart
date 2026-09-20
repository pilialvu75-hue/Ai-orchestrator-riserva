import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_staging_reader_io.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_workspace_promoter.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_executor.dart';

void main() {
  group('WorkshopAirLabWorkspacePromoter', () {
    late Directory temp;
    setUp(() async => temp =
        await Directory.systemTemp.createTemp('airlab-promotion-'));
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('promotes staging to VirtualWorkspace, never directly to gateway',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{
        'lib/app.dart': 'old-app',
        'lib/remove.dart': 'remove-me',
      });
      final session = await _session(gateway);
      final root = Directory('${temp.path}/staging');
      await Directory('${root.path}/lib').create(recursive: true);
      await File('${root.path}/lib/app.dart').writeAsString('new-app');
      await File('${root.path}/lib/new.dart').writeAsString('new-file');
      final result = _airLabResult(changedFiles: const <String>[
        'lib/app.dart', 'lib/new.dart', 'lib/remove.dart']);

      final promotion = await const WorkshopAirLabWorkspacePromoter().promote(
        session: session,
        executionResult: result,
        stagingRoot: root.path,
        reader: const WorkshopAirLabIoStagingReader());

      expect(promotion.additions, 1);
      expect(promotion.modifications, 1);
      expect(promotion.deletions, 1);
      expect(session.status, WorkspaceSessionStatus.review);
      expect(session.workspace.read('lib/app.dart'), 'new-app');
      expect(gateway.files['lib/app.dart'], 'old-app');
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);

      session.beginValidation();
      session.approveApply();
      await session.apply();
      expect(session.status, WorkspaceSessionStatus.completed);
      expect(gateway.files['lib/app.dart'], 'new-app');
      expect(gateway.files['lib/new.dart'], 'new-file');
      expect(gateway.files.containsKey('lib/remove.dart'), isFalse);
    });

    test('rejects provenance mismatch before VirtualWorkspace mutation',
        () async {
      final gateway = _RecordingGateway(
          files: <String, String>{'lib/app.dart': 'old-app'});
      final session = await _session(gateway);
      final root = Directory('${temp.path}/staging');
      await Directory('${root.path}/lib').create(recursive: true);
      await File('${root.path}/lib/app.dart').writeAsString('new-app');
      final result = _airLabResult(
          changedFiles: const <String>['lib/app.dart'],
          checkpointTaskId: 'different-task');
      await expectLater(
        const WorkshopAirLabWorkspacePromoter().promote(
          session: session,
          executionResult: result,
          stagingRoot: root.path,
          reader: const WorkshopAirLabIoStagingReader()),
        throwsA(isA<WorkshopAirLabPromotionException>().having(
          (error) => error.code, 'code', 'checkpoint_provenance_invalid')));
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
      expect(gateway.writeCalls, 0);
    });

    test('rejects oversized staged tampering before mutation', () async {
      final gateway = _RecordingGateway(
          files: <String, String>{'lib/app.dart': 'old-app'});
      final session = await _session(gateway);
      final root = Directory('${temp.path}/staging');
      await Directory('${root.path}/lib').create(recursive: true);
      await File('${root.path}/lib/app.dart').writeAsString('tampered-content');
      final result = _airLabResult(changedFiles: const <String>['lib/app.dart']);
      await expectLater(
        const WorkshopAirLabWorkspacePromoter().promote(
          session: session,
          executionResult: result,
          stagingRoot: root.path,
          reader: WorkshopAirLabIoStagingReader(maxFileBytes: 4)),
        throwsA(isA<WorkshopAirLabPromotionException>().having(
          (error) => error.code, 'code', 'staged_file_too_large')));
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
    });

    test('rejects traversal before staging inspection', () async {
      final gateway = _RecordingGateway(
          files: <String, String>{'lib/app.dart': 'old-app'});
      final session = await _session(gateway);
      final root = Directory('${temp.path}/staging');
      await root.create(recursive: true);
      final result = _airLabResult(changedFiles: const <String>['../outside.dart']);
      await expectLater(
        const WorkshopAirLabWorkspacePromoter().promote(
          session: session,
          executionResult: result,
          stagingRoot: root.path,
          reader: const WorkshopAirLabIoStagingReader()),
        throwsA(isA<WorkshopAirLabPromotionException>().having(
          (error) => error.code, 'code', 'path_traversal')));
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(session.hasChanges, isFalse);
    });
  });
}

Future<WorkspaceSession> _session(_RecordingGateway gateway) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'workspace-request',
      title: 'AIrLab staging promotion',
      instruction: 'Promote only through normal Cantiere guardrails.'),
    gateway: gateway);
  await session.initialize();
  return session;
}

WorkshopTaskExecutionResult _airLabResult({
  required List<String> changedFiles,
  String checkpointTaskId = 'airlab-task',
}) => WorkshopTaskExecutionResult(
  taskId: 'airlab-task',
  status: WorkshopTaskStatus.waitingApproval,
  checkpoint: WorkshopTaskCheckpoint(
    id: 'airlab-task-checkpoint',
    createdAt: DateTime.utc(2026, 9, 17, 14),
    phase: 'airlab-staged-awaiting-approval',
    completedSteps: const <String>['guard-approved', 'airlab-staging-complete'],
    changedFiles: changedFiles,
    metadata: <String, dynamic>{
      'request_id': 'airlab-request-1',
      'engine_id': 'airlab-mock',
      'task_id': checkpointTaskId,
      'stagingOnly': true,
      'repositoryModified': false,
      'operationCount': changedFiles.length,
    }),
  changedFiles: changedFiles,
  metadata: <String, dynamic>{
    'executor': 'airlab',
    'requestId': 'airlab-request-1',
    'engineId': 'airlab-mock',
    'repositoryModified': false,
    'stagingOnly': true,
    'promotionRequired': true,
    'operationCount': changedFiles.length,
  });

final class _RecordingGateway implements GitWorkspaceGateway {
  _RecordingGateway({required Map<String, String> files})
      : files = Map<String, String>.from(files);
  final Map<String, String> files;
  int writeCalls = 0;
  int deleteCalls = 0;
  int commitCalls = 0;
  int pushCalls = 0;
  int pullRequestCalls = 0;
  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
      repository: 'test/repository', branch: 'main');
  @override
  Future<String?> readFile(String path) async => files[path];
  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);
  @override
  Future<List<String>> listFiles({String? directory}) async =>
      files.keys.toList(growable: false);
  @override
  Future<void> createBranch(String branchName) async {}
  @override
  Future<void> writeFile({required String path, required String content}) async {
    writeCalls += 1;
    files[path] = content;
  }
  @override
  Future<void> deleteFile(String path) async {
    deleteCalls += 1;
    files.remove(path);
  }
  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);
  @override
  Future<String> commit(String message) async {
    commitCalls += 1;
    return 'commit';
  }
  @override
  Future<void> push() async => pushCalls += 1;
  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async {
    pullRequestCalls += 1;
    return 'pr';
  }
}
