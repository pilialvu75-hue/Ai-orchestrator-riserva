import 'dart:io';

import 'package:ai_orchestrator/app_factory/workspace/local_git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/virtual_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
