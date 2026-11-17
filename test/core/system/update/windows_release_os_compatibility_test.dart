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
  TestWidgetsFlutterBinding.ensureInitialized();

  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  Map<String, Object> windowsRelease({
    required String tag,
    required String title,
    required String notes,
  }) =>
      <String, Object>{
        'tag_name': tag,
        'name': title,
        'body': notes,
        'draft': false,
        'prerelease': tag.contains('-'),
        'assets': <Object>[
          <String, Object>{
            'name': 'AI-Orchestrator-Setup-x64.exe',
            'browser_download_url':
                'https://github.com/example/repo/releases/download/'
                    '$tag/AI-Orchestrator-Setup-x64.exe',
            'size': 42000000,
            'digest': 'sha256:$digest',
          },
        ],
      };

  final legacyBeta = windowsRelease(
    tag: 'v1.0.16-beta+100012',
    title: 'AIVEXUS 1.0.16 Beta - Windows 8.1 recovery QA',
    notes: 'WINDOWS 8.1 ONLY beta alias. '
        'Not installable on Windows 10/11.',
  );
  final modernBeta = windowsRelease(
    tag: 'v1.0.15-beta+200023',
    title: 'AIVEXUS Windows Computer Use',
    notes: 'Windows beta for modern desktop testing.',
  );

  Future<UpdateCheckResult> check({
    required String osVersion,
    List<Map<String, Object>>? releases,
    SharedPreferences? preferences,
    http.Client? client,
    bool allowCachedFallback = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final httpClient = client ??
        MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode(releases ?? <Map<String, Object>>[
                legacyBeta,
                modernBeta,
              ]),
              200,
            );
          }
          return http.Response('missing', 404);
        });
    final checker = UpdateChecker(
      httpClient: httpClient,
      preferences: prefs,
      comparator: const VersionComparator(),
      manifestUrl: 'https://example.com/version.json',
      githubOwner: 'example',
      githubRepo: 'repo',
      targetPlatform: UpdateTargetPlatform.windows,
      windowsOperatingSystemVersion: osVersion,
    );
    return checker.checkLatestManifest(
      preferredChannel: ReleaseChannel.beta,
      allowCachedFallback: allowCachedFallback,
    );
  }

  test('Windows 11 excludes explicit Win8.1-only beta but keeps modern beta',
      () async {
    final result = await check(osVersion: 'Windows 11 Pro 10.0.26100');
    expect(result.manifest, isNotNull);
    expect(result.manifest!.version, 'v1.0.15.200023-beta');
  });

  test('Windows 10 also excludes explicit Win8.1-only beta', () async {
    final result = await check(osVersion: 'Windows 10 Pro 10.0.19045');
    expect(result.manifest!.version, 'v1.0.15.200023-beta');
  });

  test('Windows 8.1 still sees its authorized recovery beta', () async {
    final result = await check(osVersion: 'Windows 8.1 6.3.9600');
    expect(result.manifest!.version, 'v1.0.16.100012-beta');
  });

  test('an incidental mention of Windows 8.1 is not an exclusion', () async {
    final result = await check(
      osVersion: 'Windows 11 Pro 10.0.26100',
      releases: <Map<String, Object>>[
        windowsRelease(
          tag: 'v1.0.16-beta+100014',
          title: 'Multiplatform desktop beta',
          notes: 'Windows 8.1 compatibility discussed, '
              'with Windows 10 and 11 also supported.',
        ),
      ],
    );
    expect(result.manifest!.version, 'v1.0.16.100014-beta');
  });

  test('Windows 11 rejects a cached Win8.1-only candidate', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final legacyManifest = UpdateManifest.fromJson(<String, Object>{
      'versionName': '1.0.16-beta+100012',
      'channel': 'beta',
      'windowsUrl': 'https://example.com/AI-Orchestrator-Setup-x64.exe',
      'windowsSizeBytes': 42000000,
      'windowsSha256': digest,
      'changelog': 'WINDOWS 8.1 ONLY beta alias',
    });
    await prefs.setString(
      'system.update.cached_manifest.v2.beta',
      jsonEncode(legacyManifest.toJson()),
    );
    final result = await check(
      osVersion: 'Windows 11 Pro 10.0.26100',
      preferences: prefs,
      allowCachedFallback: true,
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    expect(result.manifest, isNull);
  });

  test('Windows 11 rejects a Win8.1-only version.json', () async {
    final result = await check(
      osVersion: 'Windows 11 Pro 10.0.26100',
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response('unavailable', 503);
        }
        return http.Response(jsonEncode(<String, Object>{
          'versionName': '1.0.16-beta+100012',
          'channel': 'beta',
          'windowsUrl': 'https://example.com/AI-Orchestrator-Setup-x64.exe',
          'windowsSizeBytes': 42000000,
          'windowsSha256': digest,
          'changelog': 'WINDOWS 8.1 ONLY beta alias',
        }), 200);
      }),
    );
    expect(result.manifest, isNull);
  });
}
