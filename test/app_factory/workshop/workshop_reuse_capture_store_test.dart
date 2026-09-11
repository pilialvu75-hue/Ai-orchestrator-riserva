import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_capture_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library_store.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('captures only ready sufficiently verified emissions', () {
    final service = const WorkshopReuseCaptureService();
    final ready = _package();

    final accepted = service.captureEmission(
      package: ready,
      validationScore: 0.95,
      description: 'Verified invoice application with customers and invoices',
      capabilities: const <String>['customers', 'invoices'],
      tags: const <String>['billing', 'invoice'],
      entryPaths: const <String>['lib/main.dart'],
      sourceProjectId: 'project-1',
    );

    expect(accepted, isNotNull);
    expect(accepted!.origin, WorkshopReusableAssetOrigin.completedProject);
    expect(accepted.kind, WorkshopReusableAssetKind.projectTemplate);
    expect(accepted.artifactPath, 'build/app.apk');
    expect(accepted.target, 'android');
    expect(accepted.capabilities, const <String>['customers', 'invoices']);

    final rejected = service.captureEmission(
      package: ready,
      validationScore: 0.4,
      description: 'Not verified enough',
      capabilities: const <String>['customers'],
    );

    expect(rejected, isNull);
  });

  test('does not capture an emission without an artifact', () {
    final service = const WorkshopReuseCaptureService();
    final invalid = _package(artifactPath: '');

    final asset = service.captureEmission(
      package: invalid,
      validationScore: 1,
      description: 'Invalid package',
      capabilities: const <String>['x'],
    );

    expect(asset, isNull);
  });

  test('persists and restores the local reuse library', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = WorkshopReuseLibraryStore(
      preferences: PreferencesService(preferences),
    );
    final library = WorkshopReuseLibrary();

    final captured = const WorkshopReuseCaptureService().captureAndRegister(
      library: library,
      package: _package(),
      validationScore: 0.97,
      description: 'Reusable invoice app',
      capabilities: const <String>['customers', 'invoices'],
      tags: const <String>['billing'],
    );

    expect(captured, isTrue);
    await store.save(library);

    final restored = await store.load();
    expect(restored.length, 1);
    expect(restored.assets.single.name, 'Invoice Pro');
    expect(restored.assets.single.validationScore, 0.97);

    await store.clear();
    expect((await store.load()).length, 0);
  });
}

WorkshopAppEmissionPackage _package({String artifactPath = 'build/app.apk'}) {
  return WorkshopAppEmissionPackage(
    id: 'package-1',
    requestId: 'request-1',
    target: 'android',
    artifactPath: artifactPath,
    createdAt: DateTime.utc(2026, 9, 11),
    appName: 'Invoice Pro',
    version: '1.0.0',
  );
}
