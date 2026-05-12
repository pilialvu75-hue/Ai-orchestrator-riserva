import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.manifest,
    required this.usedCache,
    this.errorMessage,
  });

  final UpdateManifest? manifest;
  final bool usedCache;
  final String? errorMessage;
}

class UpdateChecker {
  UpdateChecker({
    required http.Client httpClient,
    required SharedPreferences preferences,
    required VersionComparator comparator,
    required this.manifestUrl,
    required this.githubOwner,
    required this.githubRepo,
  })  : _httpClient = httpClient,
        _preferences = preferences,
        _comparator = comparator;

  final http.Client _httpClient;
  final SharedPreferences _preferences;
  final VersionComparator _comparator;

  final String manifestUrl;
  final String githubOwner;
  final String githubRepo;

  static const String _cachedManifestLegacyKey = 'system.update.cached_manifest';
  static const String _cachedManifestKeyPrefix = 'system.update.cached_manifest.v2';

  Future<UpdateCheckResult> checkLatestManifest({
    required ReleaseChannel preferredChannel,
  }) async {
    _logUpdate('Starting manifest check. preferredChannel=$preferredChannel');
    _logVersion('version.json url: $manifestUrl');
    final errors = <String>[];
    try {
      final resolved = await Future.wait<UpdateManifest?>([
        _fetchRemoteManifestSafe(preferredChannel, errors),
        _fetchFromGitHubReleasesSafe(preferredChannel, errors),
      ]);
      final fromManifest = resolved[0];
      final fromGitHub = resolved[1];
      final remoteLatest = _pickNewestManifest(
        fromManifest,
        fromGitHub,
      );
      if (remoteLatest != null) {
        _logVersion(
          'Resolved latest manifest version=${remoteLatest.version} versionCode=${remoteLatest.versionCode ?? '-'} url=${remoteLatest.apkUrl}',
        );
        await _cacheManifest(remoteLatest);
        return UpdateCheckResult(manifest: remoteLatest, usedCache: false);
      }
    } catch (e) {
      _logUpdate('Update check error: $e');
      errors.add(e.toString());
      final cached = await getCachedManifest(
        preferredChannel: preferredChannel,
      );
      if (cached != null) {
        _logUpdate('Using cached manifest version=${cached.version}');
        return UpdateCheckResult(
          manifest: cached,
          usedCache: true,
          errorMessage: errors.join(' | '),
        );
      }
      return UpdateCheckResult(
        manifest: null,
        usedCache: false,
        errorMessage: errors.join(' | '),
      );
    }

    _logUpdate('No remote update data, falling back to cache');
    final cached = await getCachedManifest(
      preferredChannel: preferredChannel,
    );
    return UpdateCheckResult(
      manifest: cached,
      usedCache: cached != null,
      errorMessage: cached == null
          ? (errors.isEmpty
              ? 'No update data available'
              : errors.join(' | '))
          : null,
    );
  }

  Future<UpdateManifest?> _fetchRemoteManifestSafe(
    ReleaseChannel preferredChannel,
    List<String> errors,
  ) async {
    try {
      final manifest = await _fetchRemoteManifest(preferredChannel);
      if (manifest != null) {
        _logVersion(
          'Latest from version.json: version=${manifest.version} versionCode=${manifest.versionCode ?? '-'}',
        );
      }
      return manifest;
    } catch (error) {
      _logUpdate('Manifest fetch failed: $error');
      errors.add('manifest: $error');
      return null;
    }
  }

  Future<UpdateManifest?> _fetchFromGitHubReleasesSafe(
    ReleaseChannel preferredChannel,
    List<String> errors,
  ) async {
    try {
      final manifest = await _fetchFromGitHubReleases(preferredChannel);
      if (manifest != null) {
        _logVersion(
          'Latest from GitHub releases: version=${manifest.version} versionCode=${manifest.versionCode ?? '-'}',
        );
      }
      return manifest;
    } catch (error) {
      _logUpdate('GitHub releases fetch failed: $error');
      errors.add('github: $error');
      return null;
    }
  }

  UpdateManifest? _pickNewestManifest(
    UpdateManifest? first,
    UpdateManifest? second,
  ) {
    if (first == null) return second;
    if (second == null) return first;
    final comparison = _comparator.compare(second.version, first.version);
    _logVersion(
      'Comparing remote versions: first=${first.version} second=${second.version} compare=$comparison',
    );
    if (comparison >= 0) {
      _logVersion(
        'Selecting second manifest (GitHub tie-break or newer): ${second.version}',
      );
      return second;
    }
    _logVersion('Selecting first manifest: ${first.version}');
    return first;
  }

  Future<UpdateManifest?> _fetchRemoteManifest(ReleaseChannel preferredChannel) async {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null) {
      _logVersion('Invalid manifest URL: $manifestUrl');
      return null;
    }

    _logUpdate('Fetching remote version.json from: $uri');
    final response = await _httpClient
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));

    _logUpdate(
      'Remote version.json response status=${response.statusCode} bytes=${response.bodyBytes.length}',
    );
    if (response.statusCode != 200 || response.body.isEmpty) {
      _logUpdate('Remote version.json unavailable or empty');
      return null;
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Manifest JSON must be an object');
    }
    _logVersion('Parsed version.json: $decoded');

    final manifest = UpdateManifest.fromJson(decoded);
    _logVersion(
      'Manifest parsed version=${manifest.version} versionCode=${manifest.versionCode ?? '-'} channel=${manifest.channel}',
    );
    if (!preferredChannel.allows(manifest.channel)) {
      _logVersion(
        'Manifest channel rejected: ${manifest.channel} not allowed for $preferredChannel',
      );
      return null;
    }
    return manifest;
  }

  Future<UpdateManifest?> _fetchFromGitHubReleases(
    ReleaseChannel preferredChannel,
  ) async {
    final uri = Uri.parse(
      'https://api.github.com/repos/pilialvu75-hue/AI-Orchestrator-Core/releases',
    );
    _logUpdate('Fetching GitHub releases metadata from: $uri');
    final response = await _httpClient.get(
      uri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ).timeout(const Duration(seconds: 15));

    _logUpdate(
      'GitHub releases response status=${response.statusCode} bytes=${response.bodyBytes.length}',
    );
    if (response.statusCode != 200 || response.body.isEmpty) {
      _logUpdate('GitHub releases unavailable or empty');
      return null;
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException('GitHub releases payload is not a list');
    }

    UpdateManifest? best;
    for (final item in decoded) {
      if (item is! Map) continue;
      final release = Map<String, dynamic>.from(item);
      if (release['draft'] == true) continue;

      final channel = _releaseChannelFromGitHubRelease(release);
      if (!preferredChannel.allows(channel)) continue;

      final tagName = (release['tag_name'] as String?)?.trim() ?? '';
      final version = _normalizeVersionFromTag(tagName);
      if (_comparator.parse(version) == null) continue;

      final apkUrl = _extractApkAssetUrl(release);
      if (apkUrl == null) continue;

      final manifest = UpdateManifest(
        version: version,
        versionCode: null,
        channel: channel,
        minSupported: version,
        apkUrl: apkUrl,
        changelog: (release['body'] as String?)?.trim() ?? '',
        critical: false,
      );

      if (best == null ||
          _comparator.compare(manifest.version, best.version) > 0) {
        best = manifest;
      }
    }

    return best;
  }

  ReleaseChannel _releaseChannelFromGitHubRelease(Map<String, dynamic> release) {
    final tagName = ((release['tag_name'] as String?) ?? '').toLowerCase();
    if (tagName.contains('nightly')) return ReleaseChannel.nightly;
    if (tagName.contains('dev')) return ReleaseChannel.dev;
    if (tagName.contains('beta')) return ReleaseChannel.beta;
    if (release['prerelease'] == true) return ReleaseChannel.beta;
    return ReleaseChannel.stable;
  }

  String _normalizeVersionFromTag(String tag) {
    final normalized = tag.replaceFirst(RegExp(r'^v'), '');
    if (_comparator.parse(normalized) != null) return normalized;
    final match = RegExp(r'(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)')
        .firstMatch(normalized);
    return match?.group(1) ?? normalized;
  }

  String? _extractApkAssetUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;

    for (final rawAsset in assets) {
      if (rawAsset is! Map) continue;
      final asset = Map<String, dynamic>.from(rawAsset);
      final name = ((asset['name'] as String?) ?? '').toLowerCase();
      final url = (asset['browser_download_url'] as String?)?.trim();
      if (url == null || url.isEmpty) continue;
      if (name.endsWith('Ai-Orchestrator-Core-v.apk') || url.toLowerCase().endsWith('.apk')) {
        final uri = Uri.tryParse(url);
        if (uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty) {
          return url;
        }
      }
    }

    return null;
  }

  String _cacheKeyForChannel(ReleaseChannel channel) =>
      '$_cachedManifestKeyPrefix.${channel.storageValue}';

  Future<UpdateManifest?> getCachedManifest({
    ReleaseChannel? preferredChannel,
  }) async {
    String? raw;
    if (preferredChannel != null) {
      raw = _preferences.getString(_cacheKeyForChannel(preferredChannel));
    } else {
      raw = _preferences.getString(_cacheKeyForChannel(ReleaseChannel.stable));
    }
    raw ??= _preferences.getString(_cachedManifestLegacyKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final manifest = UpdateManifest.fromJson(decoded);
      if (preferredChannel != null &&
          !preferredChannel.allows(manifest.channel)) {
        return null;
      }
      return manifest;
    } catch (error) {
      _logUpdate('Cached manifest decode failed: $error');
      return null;
    }
  }

  Future<void> _cacheManifest(UpdateManifest manifest) async {
    final key = _cacheKeyForChannel(manifest.channel);
    _logUpdate('Caching manifest version=${manifest.version} key=$key');
    await _preferences.setString(
      key,
      jsonEncode(manifest.toJson()),
    );
  }

  void _logUpdate(String message) => debugPrint('[UPDATE] $message');
  void _logVersion(String message) => debugPrint('[VERSION] $message');
}
