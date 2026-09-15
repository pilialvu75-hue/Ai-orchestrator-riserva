import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/core/system/update/version_parser.dart';

enum UpdateTargetPlatform {
  android,
  windows,
}

class UpdateArtifact {
  const UpdateArtifact({
    required this.url,
    required this.fileName,
    this.sizeBytes,
    this.sha256,
  });

  final String url;
  final String fileName;
  final int? sizeBytes;
  final String? sha256;
}

class UpdateManifest {
  static const String defaultMinSupportedVersion = '0.0.0';

  const UpdateManifest({
    required this.version,
    this.versionCode,
    required this.channel,
    required this.minSupported,
    required this.apkUrl,
    this.apkFileName,
    this.apkSizeBytes,
    this.windowsUrl,
    this.windowsFileName,
    this.windowsSizeBytes,
    this.windowsSha256,
    required this.changelog,
    required this.critical,
  });

  final String version;
  final int? versionCode;
  final ReleaseChannel channel;
  final String minSupported;
  final String apkUrl;
  final String? apkFileName;
  final int? apkSizeBytes;
  final String? windowsUrl;
  final String? windowsFileName;
  final int? windowsSizeBytes;
  final String? windowsSha256;
  final String changelog;
  final bool critical;

  UpdateArtifact get androidArtifact => UpdateArtifact(
        url: apkUrl,
        fileName: apkFileName ?? Uri.parse(apkUrl).pathSegments.last,
        sizeBytes: apkSizeBytes,
      );

  UpdateArtifact? get windowsArtifact {
    final url = windowsUrl;
    final fileName = windowsFileName;
    if (url == null || fileName == null) return null;
    return UpdateArtifact(
      url: url,
      fileName: fileName,
      sizeBytes: windowsSizeBytes,
      sha256: windowsSha256,
    );
  }

  UpdateArtifact? artifactFor(UpdateTargetPlatform target) => switch (target) {
        UpdateTargetPlatform.android => androidArtifact,
        UpdateTargetPlatform.windows => windowsArtifact,
      };

  bool isCompatibleWith({
    required String currentVersion,
    required VersionComparator comparator,
  }) {
    return comparator.isCompatible(
      currentVersion: currentVersion,
      minSupported: minSupported,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        if (versionCode != null) 'versionCode': versionCode,
        'channel': channel.storageValue,
        'min_supported': minSupported,
        'apk_url': apkUrl,
        if (apkFileName != null) 'apk_file_name': apkFileName,
        if (apkSizeBytes != null) 'apk_size_bytes': apkSizeBytes,
        if (windowsUrl != null) 'windows_url': windowsUrl,
        if (windowsFileName != null) 'windows_file_name': windowsFileName,
        if (windowsSizeBytes != null) 'windows_size_bytes': windowsSizeBytes,
        if (windowsSha256 != null) 'windows_sha256': windowsSha256,
        'changelog': changelog,
        'critical': critical,
      };

  static UpdateManifest fromJson(Map<String, dynamic> json) {
    const parser = VersionParser();
    // Support both the internal manifest format (version/apk_url/min_supported)
    // and the simplified version.json format (versionName/apkUrl/versionCode).
    final rawVersion = ((json['version'] ?? json['versionName']) as String?)?.trim();
    final rawApkUrl = ((json['apk_url'] ?? json['apkUrl']) as String?)?.trim();
    final rawMinSupported = (json['min_supported'] as String?)?.trim();
    final rawVersionCode = json['versionCode'];
    final rawApkFileName =
        ((json['apk_file_name'] ?? json['apkFileName']) as String?)?.trim();
    final rawApkSizeBytes = json['apk_size_bytes'] ?? json['apkSizeBytes'];
    final rawWindowsUrl =
        ((json['windows_url'] ?? json['windowsUrl']) as String?)?.trim();
    final rawWindowsFileName =
        ((json['windows_file_name'] ?? json['windowsFileName']) as String?)?.trim();
    final rawWindowsSizeBytes =
        json['windows_size_bytes'] ?? json['windowsSizeBytes'];
    final rawWindowsSha256 =
        ((json['windows_sha256'] ?? json['windowsSha256']) as String?)?.trim();

    if (rawVersion == null || rawVersion.isEmpty) {
      throw const FormatException('Invalid manifest: missing version');
    }
    if (rawApkUrl == null || rawApkUrl.isEmpty) {
      throw const FormatException('Invalid manifest: missing apk_url');
    }

    final parsedVersion = parser.parse(rawVersion);
    if (parsedVersion == null) {
      throw FormatException('Invalid manifest: malformed version "$rawVersion"');
    }

    final apkUri = _validateHttpUrl(rawApkUrl, fieldName: 'apk_url');

    final derivedApkFileName =
        rawApkFileName ??
        (apkUri.pathSegments.isNotEmpty ? apkUri.pathSegments.last.trim() : '');
    if (derivedApkFileName.isEmpty ||
        derivedApkFileName.contains('/') ||
        !derivedApkFileName.toLowerCase().endsWith('.apk')) {
      throw FormatException(
        'Invalid manifest: apk filename must be a non-empty .apk name, got: $derivedApkFileName',
      );
    }

    String? windowsUrl;
    String? windowsFileName;
    int? windowsSizeBytes;
    String? windowsSha256;
    final hasWindowsMetadata =
        rawWindowsUrl != null ||
        rawWindowsFileName != null ||
        rawWindowsSizeBytes != null ||
        rawWindowsSha256 != null;
    if (hasWindowsMetadata) {
      if (rawWindowsUrl == null || rawWindowsUrl.isEmpty) {
        throw const FormatException(
          'Invalid manifest: windows_url is required when Windows metadata is present',
        );
      }
      final windowsUri =
          _validateHttpUrl(rawWindowsUrl, fieldName: 'windows_url');
      final derivedWindowsFileName =
          rawWindowsFileName ??
          (windowsUri.pathSegments.isNotEmpty
              ? windowsUri.pathSegments.last.trim()
              : '');
      if (derivedWindowsFileName.isEmpty ||
          derivedWindowsFileName.contains('/') ||
          !derivedWindowsFileName.toLowerCase().endsWith('.exe')) {
        throw FormatException(
          'Invalid manifest: Windows filename must be a non-empty .exe name, got: $derivedWindowsFileName',
        );
      }
      windowsUrl = rawWindowsUrl;
      windowsFileName = derivedWindowsFileName;
      windowsSizeBytes = switch (rawWindowsSizeBytes) {
        int value => value,
        String value => int.tryParse(value.trim()),
        _ => null,
      };
      if (windowsSizeBytes != null && windowsSizeBytes <= 0) {
        throw FormatException(
          'Invalid manifest: Windows installer size must be > 0, got: $windowsSizeBytes',
        );
      }
      if (rawWindowsSha256 != null && rawWindowsSha256.isNotEmpty) {
        final normalizedSha = rawWindowsSha256.toLowerCase();
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedSha)) {
          throw const FormatException(
            'Invalid manifest: windows_sha256 must be a 64-character hexadecimal SHA-256',
          );
        }
        windowsSha256 = normalizedSha;
      }
    }

    // Missing min_supported must never block updates by default.
    final rawResolvedMinSupported =
        (rawMinSupported != null && rawMinSupported.isNotEmpty)
            ? rawMinSupported
            : defaultMinSupportedVersion;
    final parsedMinSupported = parser.parse(rawResolvedMinSupported);
    if (parsedMinSupported == null) {
      throw FormatException(
        'Invalid manifest: malformed min_supported "$rawResolvedMinSupported"',
      );
    }
    final versionCode = switch (rawVersionCode) {
      int value => value,
      String value => int.tryParse(value.trim()),
      _ => null,
    };
    final apkSizeBytes = switch (rawApkSizeBytes) {
      int value => value,
      String value => int.tryParse(value.trim()),
      _ => null,
    };
    if (apkSizeBytes != null && apkSizeBytes <= 0) {
      throw FormatException(
        'Invalid manifest: apk size must be > 0, got: $apkSizeBytes',
      );
    }

    return UpdateManifest(
      version: parsedVersion.displayValue,
      versionCode: versionCode,
      channel: json['channel'] is String
          ? ReleaseChannel.fromString(json['channel'] as String?)
          : parsedVersion.channel,
      minSupported: parsedMinSupported.displayValue,
      apkUrl: rawApkUrl,
      apkFileName: derivedApkFileName,
      apkSizeBytes: apkSizeBytes,
      windowsUrl: windowsUrl,
      windowsFileName: windowsFileName,
      windowsSizeBytes: windowsSizeBytes,
      windowsSha256: windowsSha256,
      changelog: (json['changelog'] as String?)?.trim() ?? '',
      critical: json['critical'] == true || json['forceUpdate'] == true,
    );
  }

  static Uri _validateHttpUrl(
    String rawUrl, {
    required String fieldName,
  }) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      throw FormatException(
        'Invalid manifest: $fieldName must be http/https, got: $rawUrl',
      );
    }
    return uri;
  }
}
