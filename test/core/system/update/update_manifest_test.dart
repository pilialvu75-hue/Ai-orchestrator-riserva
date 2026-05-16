import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';

void main() {
  test('parses valid manifest', () {
    final manifest = UpdateManifest.fromJson(const {
      'version': '1.0.8.12',
      'channel': 'stable',
      'min_supported': '1.0.5',
      'apk_url': 'https://example.com/app.apk',
      'changelog': 'Fixes and improvements',
      'critical': false,
    });

    expect(manifest.version, 'v1.0.8.12');
    expect(manifest.channel, ReleaseChannel.stable);
    expect(manifest.minSupported, 'v1.0.5');
    expect(manifest.apkUrl, 'https://example.com/app.apk');
    expect(manifest.apkFileName, 'app.apk');
    expect(manifest.critical, isFalse);
  });

  test('parses simplified version.json format (versionName/apkUrl/forceUpdate)', () {
    final manifest = UpdateManifest.fromJson(const {
      'versionName': '1.0.12.105',
      'versionCode': 12,
      'apkUrl': 'https://example.com/app-release.apk',
      'changelog': 'OTA fix release',
      'forceUpdate': false,
    });

    expect(manifest.version, 'v1.0.12.105');
    expect(manifest.apkUrl, 'https://example.com/app-release.apk');
    // min_supported defaults to version when absent
    expect(manifest.minSupported, 'v1.0.12.105');
    expect(manifest.apkFileName, 'app-release.apk');
    expect(manifest.critical, isFalse);
  });

  test('forceUpdate:true maps to critical:true', () {
    final manifest = UpdateManifest.fromJson(const {
      'versionName': '1.0.13',
      'apkUrl': 'https://example.com/app.apk',
      'forceUpdate': true,
    });
    expect(manifest.critical, isTrue);
  });

  test('throws on missing required fields', () {
    expect(
      () => UpdateManifest.fromJson(const {
        'version': '1.0.8',
      }),
      throwsFormatException,
    );
  });

  test('throws on malformed versions and invalid apk metadata', () {
    expect(
      () => UpdateManifest.fromJson(const {
        'version': '1.0',
        'apk_url': 'https://example.com/app.apk',
      }),
      throwsFormatException,
    );
    expect(
      () => UpdateManifest.fromJson(const {
        'version': '1.0.12',
        'apk_url': 'https://example.com/not-an-apk.zip',
      }),
      throwsFormatException,
    );
    expect(
      () => UpdateManifest.fromJson(const {
        'version': '1.0.12',
        'apk_url': 'https://example.com/app.apk',
        'apk_size_bytes': 0,
      }),
      throwsFormatException,
    );
  });
}
