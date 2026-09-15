import 'dart:convert';

import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/update_checker.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const manifestUrl = 'https://example.com/version.json';
  const owner = 'pilialvu75-hue';
  const repo = 'Ai-orchestrator-riserva';
  const windowsSha =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Future<SharedPreferences> preferencesWith(
    Map<String, Object> initialValues,
  ) async {
    SharedPreferences.setMockInitialValues(initialValues);
    return SharedPreferences.getInstance();
  }

  test(
    'Windows ignores Android-only version.json and selects verified Setup.exe from GitHub release',
    () async {
      final preferences = await preferencesWith(const {});
      final client = MockClient((request) async {
        if (request.url.toString() == manifestUrl) {
          return http.Response(
            jsonEncode(const {
              'versionName': '1.0.12+100',
              'apkUrl': 'https://example.com/app-release.apk',
            }),
            200,
          );
        }
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode([
              {
                'tag_name': 'v1.0.12+1843',
                'draft': false,
                'prerelease': false,
                'body': 'Coordinated Windows release',
                'assets': [
                  {
                    'name': 'app-release.apk',
                    'browser_download_url':
                        'https://github.com/example/app-release.apk',
                    'size': 165000000,
                    'digest': 'sha256:$windowsSha',
                  },
                  {
                    'name': 'AI-Orchestrator-Setup-x64.exe',
                    'browser_download_url':
                        'https://github.com/example/AI-Orchestrator-Setup-x64.exe',
                    'size': 41447219,
                    'digest': 'sha256:$windowsSha',
                  },
                ],
              },
            ]),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final checker = UpdateChecker(
        httpClient: client,
        preferences: preferences,
        comparator: const VersionComparator(),
        manifestUrl: manifestUrl,
        githubOwner: owner,
        githubRepo: repo,
        targetPlatform: UpdateTargetPlatform.windows,
      );

      final result = await checker.checkLatestManifest(
        preferredChannel: ReleaseChannel.stable,
        allowCachedFallback: false,
      );

      expect(result.manifest, isNotNull);
      expect(result.manifest!.version, contains('1843'));
      expect(
        result.manifest!.windowsArtifact!.fileName,
        'AI-Orchestrator-Setup-x64.exe',
      );
      expect(result.manifest!.windowsArtifact!.sizeBytes, 41447219);
      expect(result.manifest!.windowsArtifact!.sha256, windowsSha);
      expect(result.manifest!.androidArtifact.fileName, 'app-release.apk');
    },
  );

  test('Android keeps accepting APK-only GitHub releases', () async {
    final preferences = await preferencesWith(const {});
    final client = MockClient((request) async {
      if (request.url.toString() == manifestUrl) {
        return http.Response('not found', 404);
      }
      if (request.url.host == 'api.github.com') {
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'v1.0.13+2000',
              'draft': false,
              'prerelease': false,
              'assets': [
                {
                  'name': 'app-release.apk',
                  'browser_download_url':
                      'https://github.com/example/app-release.apk',
                  'size': 165000000,
                },
              ],
            },
          ]),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final checker = UpdateChecker(
      httpClient: client,
      preferences: preferences,
      comparator: const VersionComparator(),
      manifestUrl: manifestUrl,
      githubOwner: owner,
      githubRepo: repo,
    );

    final result = await checker.checkLatestManifest(
      preferredChannel: ReleaseChannel.stable,
      allowCachedFallback: false,
    );

    expect(result.manifest, isNotNull);
    expect(result.manifest!.androidArtifact.fileName, 'app-release.apk');
    expect(result.manifest!.windowsArtifact, isNull);
  });

  test('Windows fails closed when Setup.exe has no GitHub SHA-256 digest', () async {
    final preferences = await preferencesWith(const {});
    final client = MockClient((request) async {
      if (request.url.toString() == manifestUrl) {
        return http.Response('not found', 404);
      }
      if (request.url.host == 'api.github.com') {
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'v1.0.13+2001',
              'draft': false,
              'prerelease': false,
              'assets': [
                {
                  'name': 'app-release.apk',
                  'browser_download_url':
                      'https://github.com/example/app-release.apk',
                  'size': 165000000,
                },
                {
                  'name': 'AI-Orchestrator-Setup-x64.exe',
                  'browser_download_url':
                      'https://github.com/example/AI-Orchestrator-Setup-x64.exe',
                  'size': 41447219,
                },
              ],
            },
          ]),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final checker = UpdateChecker(
      httpClient: client,
      preferences: preferences,
      comparator: const VersionComparator(),
      manifestUrl: manifestUrl,
      githubOwner: owner,
      githubRepo: repo,
      targetPlatform: UpdateTargetPlatform.windows,
    );

    final result = await checker.checkLatestManifest(
      preferredChannel: ReleaseChannel.stable,
      allowCachedFallback: false,
    );

    expect(result.manifest, isNull);
  });

  test('Windows does not reuse an Android-only cached manifest', () async {
    final preferences = await preferencesWith({
      'system.update.cached_manifest': jsonEncode(const {
        'versionName': '1.0.13+2002',
        'apkUrl': 'https://example.com/app-release.apk',
      }),
    });
    final checker = UpdateChecker(
      httpClient: MockClient((_) async => http.Response('not found', 404)),
      preferences: preferences,
      comparator: const VersionComparator(),
      manifestUrl: manifestUrl,
      githubOwner: owner,
      githubRepo: repo,
      targetPlatform: UpdateTargetPlatform.windows,
    );

    final cached = await checker.getCachedManifest(
      preferredChannel: ReleaseChannel.stable,
    );

    expect(cached, isNull);
  });
}
