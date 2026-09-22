import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_verified_local_build_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorkshopBuildTarget targetNotSupportedByCurrentHost() {
    if (Platform.isWindows) return WorkshopBuildTarget.macos;
    if (Platform.isMacOS) return WorkshopBuildTarget.windows;
    return WorkshopBuildTarget.windows;
  }

  group('WorkshopVerifiedLocalBuildProvider', () {
    test('exposes offlineLocal execution mode', () {
      final provider = WorkshopVerifiedLocalBuildProvider();
      expect(
        provider.executionMode,
        WorkshopBuildExecutionMode.offlineLocal,
      );
    });

    test('fails closed before build when target host is incompatible', () async {
      final provider = WorkshopVerifiedLocalBuildProvider();
      final target = targetNotSupportedByCurrentHost();

      final result = await provider.build(
        WorkshopBuildRequest(
          id: 'verified-local-incompatible-host',
          projectId: 'project:test',
          projectPath: '/path/that/must/not/be/touched',
          target: target,
          mode: WorkshopBuildExecutionMode.offlineLocal,
        ),
      );

      expect(result.status, WorkshopBuildStatus.failed);
      expect(
        result.errors,
        contains('verified_local_toolchain_unavailable'),
      );
      expect(result.errors, isNot(contains('project_directory_missing')));
    });
  });
}
