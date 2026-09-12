import 'dart:io';

import 'package:ai_orchestrator/app_factory/workspace/local_git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_source_snapshot_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('WorkshopReuseSourceSnapshotService', () {
    test('captures allow-listed source while excluding secrets and build output',
        () async {
      final temp = await Directory.systemTemp.createTemp('reuse-capture-');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final workspace = Directory(p.join(temp.path, 'workspace'));
      final snapshots = Directory(p.join(temp.path, 'snapshots'));
      await workspace.create(recursive: true);

      await _write(workspace, 'lib/main.dart', 'void main() {}');
      await _write(workspace, 'pubspec.yaml', 'name: reusable_app');
      await _write(workspace, 'web/index.html', '<h1>Hello</h1>');
      await _write(workspace, '.env', 'API_KEY=secret');
      await _write(workspace, 'android/key.properties', 'storePassword=secret');
      await _write(workspace, 'android/local.properties', 'sdk.dir=/tmp/sdk');
      await _write(workspace, 'build/generated.txt', 'generated');
      await _write(workspace, '.dart_tool/package_config.json', '{}');
      await _write(workspace, 'android/app/release.jks', 'binary-ish');

      final snapshot = await const WorkshopReuseSourceSnapshotService().capture(
        assetId: 'invoice-template',
        workspaceRootPath: workspace.path,
        snapshotsRootPath: snapshots.path,
      );

      expect(snapshot.files, contains('lib/main.dart'));
      expect(snapshot.files, contains('pubspec.yaml'));
      expect(snapshot.files, contains('web/index.html'));
      expect(snapshot.files, isNot(contains('.env')));
      expect(snapshot.files, isNot(contains('android/key.properties')));
      expect(snapshot.files, isNot(contains('android/local.properties')));
      expect(snapshot.files, isNot(contains('build/generated.txt')));
      expect(snapshot.files, isNot(contains('.dart_tool/package_config.json')));
      expect(snapshot.files, isNot(contains('android/app/release.jks')));
      expect(File(p.join(snapshot.rootPath, 'lib/main.dart')).existsSync(), isTrue);
      expect(File(p.join(snapshot.rootPath, '.env')).existsSync(), isFalse);
    });

    test('stages snapshot only into VirtualWorkspace and preserves real files',
        () async {
      final temp = await Directory.systemTemp.createTemp('reuse-stage-');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final source = Directory(p.join(temp.path, 'source'));
      final target = Directory(p.join(temp.path, 'target'));
      final snapshots = Directory(p.join(temp.path, 'snapshots'));
      await source.create(recursive: true);
      await target.create(recursive: true);

      await _write(source, 'lib/main.dart', 'void main() => print("template");');
      await _write(source, 'lib/invoice.dart', 'class Invoice {}');
      await _write(target, 'lib/main.dart', 'void main() => print("target");');

      final service = const WorkshopReuseSourceSnapshotService();
      final snapshot = await service.capture(
        assetId: 'invoice-template',
        workspaceRootPath: source.path,
        snapshotsRootPath: snapshots.path,
      );

      final session = WorkspaceSession(
        request: WorkshopRequest(
          id: 'new-project',
          title: 'New project',
          instruction: 'Reuse invoice foundation',
          projectPath: target.path,
        ),
        gateway: LocalGitWorkspaceGateway(rootPath: target.path),
      );
      await session.initialize();

      final staged = await service.stageInto(
        snapshot: snapshot,
        session: session,
      );

      expect(staged.stagedPaths, contains('lib/invoice.dart'));
      expect(staged.skippedExistingPaths, contains('lib/main.dart'));
      expect(session.workspace.read('lib/invoice.dart'), 'class Invoice {}');
      expect(session.workspace.hasChanges, isTrue);
      expect(File(p.join(target.path, 'lib/invoice.dart')).existsSync(), isFalse);
      expect(
        await File(p.join(target.path, 'lib/main.dart')).readAsString(),
        'void main() => print("target");',
      );
    });

    test('source snapshot index round-trips descriptors', () {
      final index = WorkshopReuseSourceSnapshotIndex(
        initialSnapshots: <WorkshopReuseSourceSnapshot>[
          WorkshopReuseSourceSnapshot(
            assetId: 'asset-1',
            rootPath: '/safe/snapshot',
            files: const <String>['lib/main.dart'],
            totalBytes: 42,
            createdAt: DateTime.utc(2026, 9, 11),
          ),
        ],
      );

      final restored = WorkshopReuseSourceSnapshotIndex.fromJson(index.toJson());
      final snapshot = restored.forAsset('asset-1');

      expect(snapshot, isNotNull);
      expect(snapshot!.files, const <String>['lib/main.dart']);
      expect(snapshot.totalBytes, 42);
      expect(snapshot.createdAt, DateTime.utc(2026, 9, 11));
    });
  });
}

Future<void> _write(Directory root, String relative, String content) async {
  final file = File(p.join(root.path, relative));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
