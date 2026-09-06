import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';

void main() {
  test('production bundle keeps the exact real workspace for verification', () {
    final workspacePath = Directory.systemTemp.path;

    final bundle = WorkshopProductionLifecycleBundleFactory.createForWorkspace(
      workspaceRootPath: '  $workspacePath  ',
    );
    addTearDown(bundle.dashboardController.dispose);

    expect(bundle.workspaceRootPath, workspacePath);
  });
}
