import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

class MockUpdateChecker extends Mock implements UpdateChecker {}

class MockAndroidIntentHandler extends Mock implements AndroidIntentHandler {}

void main() {
  late MockUpdateChecker mockUpdateChecker;
  late MockAndroidIntentHandler mockIntentHandler;
  late SharedPreferences preferences;
  late UpdateManager updateManager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    mockUpdateChecker = MockUpdateChecker();
    mockIntentHandler = MockAndroidIntentHandler();
    updateManager = UpdateManager(
      updateChecker: mockUpdateChecker,
      comparator: const VersionComparator(),
      preferences: preferences,
      intentHandler: mockIntentHandler,
      currentVersion: '1.12.119+119',
    );
  });

  test('marks a newer simplified manifest as updateAvailable', () async {
    final manifest = UpdateManifest.fromJson(const {
      'versionName': '1.12.120',
      'apkUrl': 'https://example.com/app-release.apk',
      'forceUpdate': false,
    });
    when(
      () => mockUpdateChecker.checkLatestManifest(
        preferredChannel: ReleaseChannel.stable,
        allowCachedFallback: true,
      ),
    ).thenAnswer(
      (_) async => UpdateCheckResult(
        manifest: manifest,
        usedCache: false,
      ),
    );

    await updateManager.checkForUpdates();

    expect(updateManager.state.value.status, UpdateStatus.updateAvailable);
    expect(updateManager.state.value.latestManifest?.version, 'v1.12.120');
    expect(updateManager.hasDetectedNewerVersion(updateManager.state.value), isTrue);
  });

  test('blocks update via min_supported even when a newer version is detected', () async {
    final manifest = UpdateManifest.fromJson(const {
      'versionName': '1.12.120',
      'min_supported': '1.12.120',
      'apkUrl': 'https://example.com/app-release.apk',
      'forceUpdate': false,
    });
    when(
      () => mockUpdateChecker.checkLatestManifest(
        preferredChannel: ReleaseChannel.stable,
        allowCachedFallback: true,
      ),
    ).thenAnswer(
      (_) async => UpdateCheckResult(
        manifest: manifest,
        usedCache: false,
      ),
    );

    await updateManager.checkForUpdates();

    expect(updateManager.state.value.status, UpdateStatus.upToDate);
    expect(updateManager.hasDetectedNewerVersion(updateManager.state.value), isTrue);
    expect(updateManager.state.value.preferredChannel, ReleaseChannel.stable);
  });
}
