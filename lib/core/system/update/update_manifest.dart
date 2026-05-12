import 'package:ai_orchestrator/core/system/update/release_channel.dart';
import 'package:ai_orchestrator/core/system/update/version_comparator.dart';

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    this.versionCode,
    required this.channel,
    required this.minSupported,
    required this.apkUrl,
    required this.changelog,
    required this.critical,
  });

  final String version;
  final int? versionCode;
  final ReleaseChannel channel;
  final String minSupported;
  final String apkUrl;
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
        'changelog': changelog,
        'critical': critical,
      };

  static UpdateManifest fromJson(Map<String, dynamic> json) {
    // Support both the internal manifest format (version/apk_url/min_supported)
    // and the simplified version.json format (versionName/apkUrl/versionCode).
    final version = ((json['version'] ?? json['versionName']) as String?)?.trim();
    final rawApkUrl = ((json['apk_url'] ?? json['apkUrl']) as String?)?.trim();
    final rawMinSupported = (json['min_supported'] as String?)?.trim();
    final rawVersionCode = json['versionCode'];

    if (version == null || version.isEmpty) {
      throw const FormatException('Invalid manifest: missing version');
    }
    if (rawApkUrl == null || rawApkUrl.isEmpty) {
      throw const FormatException('Invalid manifest: missing apk_url');
    }

    final apkUri = Uri.tryParse(rawApkUrl);
    if (apkUri == null ||
        !(apkUri.scheme == 'https' || apkUri.scheme == 'http') ||
        apkUri.host.isEmpty) {
      throw FormatException(
        'Invalid manifest: apk_url must be http/https, got: $rawApkUrl',
      );
    }

    // min_supported defaults to the release version itself when absent.
    final minSupported =
        (rawMinSupported != null && rawMinSupported.isNotEmpty)
            ? rawMinSupported
            : version;
    final versionCode = switch (rawVersionCode) {
      int value => value,
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    return UpdateManifest(
      version: version,
      versionCode: versionCode,
      channel: ReleaseChannel.fromString(json['channel'] as String?),
      minSupported: minSupported,
      apkUrl: rawApkUrl,
      changelog: (json['changelog'] as String?)?.trim() ?? '',
      critical: json['critical'] == true || json['forceUpdate'] == true,
    );
  }
}
