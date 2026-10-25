import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_dashboard_page.dart';

void main() {
  test('platform build target preserves Android and selects native Windows',
      () {
    expect(workshopBuildTargetForPlatform(TargetPlatform.windows),
        WorkshopBuildTarget.windows);
    expect(workshopBuildTargetForPlatform(TargetPlatform.android),
        WorkshopBuildTarget.android);
    expect(workshopBuildTargetForPlatform(TargetPlatform.windows, isWeb: true),
        WorkshopBuildTarget.web);
    expect(workshopBuildActionLabel(TargetPlatform.android), contains('APK'));
    expect(workshopBuildActionLabel(TargetPlatform.windows), 'Genera app finale');
  });

  test('verified emissions survive recreation; failed builds never emit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences =
        PreferencesService(await SharedPreferences.getInstance());
    final store = WorkshopAppEmissionStore(preferences);
    WorkshopBuildResult result(String id, WorkshopBuildStatus status) =>
        WorkshopBuildResult(
          requestId: id,
          target: WorkshopBuildTarget.windows,
          status: status,
          startedAt: DateTime.utc(2026),
          finishedAt: DateTime.utc(2026, 1, 2),
          artifactPath: 'app/Release',
          testsPassed: true,
          analysisPassed: true,
        );
    final success = result('ok', WorkshopBuildStatus.succeeded);
    await Future.wait([
      store.recordVerifiedBuild(
          result: success, projectId: 'project', appName: 'Stella'),
      WorkshopAppEmissionStore(preferences).recordVerifiedBuild(
          result: result('second', WorkshopBuildStatus.succeeded),
          projectId: 'other',
          appName: 'Seconda'),
    ]);
    await store.recordVerifiedBuild(
        result: success, projectId: 'project', appName: 'Stella');
    expect(
        await store.recordVerifiedBuild(
            result: result('failed', WorkshopBuildStatus.failed),
            projectId: 'project',
            appName: 'Guasta'),
        isNull);
    final reopened = WorkshopAppEmissionStore(preferences).load();
    expect(reopened.length, 2);
    expect(reopened.findByRequestId('ok')!.metadata['projectId'], 'project');
    expect(reopened.findByRequestId('failed'), isNull);
  });
}
