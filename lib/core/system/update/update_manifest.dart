import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';
import 'package:ai_orchestrator/core/system/update/version_parser.dart';

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
  final String changelog;
  final bool critical;

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

    final apkUri = Uri.tryParse(rawApkUrl);
    if (apkUri == null ||
        !(apkUri.scheme == 'https' || apkUri.scheme == 'http') ||
        apkUri.host.isEmpty) {
      throw FormatException(
        'Invalid manifest: apk_url must be http/https, got: $rawApkUrl',
      );
    }

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
      changelog: (json['changelog'] as String?)?.trim() ?? '',
      critical: json['critical'] == true || json['forceUpdate'] == true,
    );
  }
}
