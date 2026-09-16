import 'package:ai_orchestrator/core/system/update/macos_update_installer.dart';
import 'package:ai_orchestrator/core/system/update/macos_update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockUpdateChecker extends Mock implements UpdateChecker {}

class _MockAndroidIntentHandler extends Mock implements AndroidIntentHandler {}

class _MockMacosInstaller extends Mock implements MacosUpdateInstallerPort {}

void main() {
  late SharedPreferences preferences;
  late _MockUpdateChecker checker;
  late _MockAndroidIntentHandler intentHandler;
  late _MockMacosInstaller installer;
  late MacosUpdateManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    checker = _MockUpdateChecker();
    intentHandler = _MockAndroidIntentHandler();
    installer = _MockMacosInstaller();
    manager = MacosUpdateManager(
      updateChecker: checker,
      comparator: const VersionComparator(),
      preferences: preferences,
      intentHandler: intentHandler,
      currentVersion: '1.0.13',
      macosInstaller: installer,
    );
  });

  tearDown(() {
    manager.stopBackgroundChecks();
  });

  test('download fails closed when no macOS artifact is available', () async {
    final result = await manager.downloadLatestApk();

    expect(result, isFalse);
    expect(manager.state.value.status, UpdateStatus.error);
    expect(manager.state.value.errorMessage, contains('macOS installer'));
    verifyNever(
      () => installer.download(
        url: any(named: 'url'),
        fileName: any(named: 'fileName'),
        finalPath: any(named: 'finalPath'),
        partialPath: any(named: 'partialPath'),
        expectedSizeBytes: any(named: 'expectedSizeBytes'),
        expectedSha256: any(named: 'expectedSha256'),
        onProgress: any(named: 'onProgress'),
      ),
    );
  });

  test('download rejects incomplete macOS integrity metadata before I/O', () async {
    final manifest = UpdateManifest.fromJson(const {
      'version': '1.0.14',
      'apk_url': 'https://example.com/app.apk',
      'macos_url': 'https://example.com/AI-Orchestrator-macOS.dmg',
    });
    manager.state.value = manager.state.value.copyWith(
      status: UpdateStatus.updateAvailable,
      latestManifest: manifest,
    );

    final result = await manager.downloadLatestApk();

    expect(result, isFalse);
    expect(manager.state.value.status, UpdateStatus.error);
    expect(manager.state.value.errorMessage, contains('size and SHA-256'));
    verifyNever(
      () => installer.download(
        url: any(named: 'url'),
        fileName: any(named: 'fileName'),
        finalPath: any(named: 'finalPath'),
        partialPath: any(named: 'partialPath'),
        expectedSizeBytes: any(named: 'expectedSizeBytes'),
        expectedSha256: any(named: 'expectedSha256'),
        onProgress: any(named: 'onProgress'),
      ),
    );
  });

  test('install launch fails closed when no verified pending DMG exists', () async {
    final result = await manager.prepareInstallIntent();

    expect(result, isFalse);
    expect(manager.state.value.status, UpdateStatus.error);
    verifyNever(
      () => installer.verify(
        filePath: any(named: 'filePath'),
        expectedSizeBytes: any(named: 'expectedSizeBytes'),
        expectedSha256: any(named: 'expectedSha256'),
      ),
    );
    verifyNever(() => installer.launch(any()));
  });
}
