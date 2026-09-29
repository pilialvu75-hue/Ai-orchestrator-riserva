import 'dart:io';

import 'package:ai_orchestrator/app_factory/workspace/local_git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/virtual_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isolated project root can be created lazily when explicitly enabled',
      () async {
    final parent = await Directory.systemTemp.createTemp(
      'cantiere-project-root-',
    );
    final projectRoot = Directory('${parent.path}/projects/project-one');

    try {
      expect(await projectRoot.exists(), isFalse);

      final gateway = LocalGitWorkspaceGateway(
        rootPath: projectRoot.path,
        createRootIfMissing: true,
      );

      final info = await gateway.openWorkspace();
      expect(info.repository, projectRoot.path);
      expect(await projectRoot.exists(), isTrue);

      await gateway.writeFile(
        path: 'lib/main.dart',
        content: 'void main() {}',
      );
      expect(await gateway.readFile('lib/main.dart'), 'void main() {}');
    } finally {
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    }
  });

  test('missing root remains fail-closed by default', () async {
    final parent = await Directory.systemTemp.createTemp(
      'cantiere-missing-root-',
    );
    final missing = Directory('${parent.path}/missing');

    try {
      final gateway = LocalGitWorkspaceGateway(rootPath: missing.path);
      await expectLater(gateway.openWorkspace(), throwsStateError);
      expect(await missing.exists(), isFalse);
    } finally {
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    }
  });

  test('binary assets stay on disk and are skipped by text VirtualWorkspace',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'cantiere-local-workspace-',
    );

    try {
      final textFile = File('${root.path}/lib/main.dart');
      await textFile.parent.create(recursive: true);
      await textFile.writeAsString('void main() {}\n');

      final binaryFile = File('${root.path}/android/app/src/main/res/icon.png');
      await binaryFile.parent.create(recursive: true);
      final binaryBytes = <int>[0x89, 0x50, 0x4e, 0x47, 0xff, 0x00, 0x80];
      await binaryFile.writeAsBytes(binaryBytes, flush: true);

      final gateway = LocalGitWorkspaceGateway(rootPath: root.path);

      expect(await gateway.readFile('lib/main.dart'), 'void main() {}\n');
      expect(
        await gateway.readFile('android/app/src/main/res/icon.png'),
        isNull,
      );

      final workspace = VirtualWorkspace(gateway: gateway);
      await workspace.initialize();

      expect(workspace.read('lib/main.dart'), 'void main() {}\n');
      expect(workspace.contains('android/app/src/main/res/icon.png'), isFalse);
      expect(await binaryFile.readAsBytes(), binaryBytes);
      expect(workspace.hasChanges, isFalse);
    } finally {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
  });
}
