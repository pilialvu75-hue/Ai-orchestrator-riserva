import 'package:ai_orchestrator/core/system/update/release_channel.dart';

class ParsedVersion {
  const ParsedVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.channel,
    this.channelBuild,
  });

  final int major;
  final int minor;
  final int patch;
  final ReleaseChannel channel;
  final int? channelBuild;
}

class VersionComparator {
  const VersionComparator();

  static final RegExp _versionRegex = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$',
  );

  ParsedVersion? parse(String version) {
    final match = _versionRegex.firstMatch(version.trim());
    if (match == null) return null;

    final major = int.tryParse(match.group(1) ?? '');
    final minor = int.tryParse(match.group(2) ?? '');
    final patch = int.tryParse(match.group(3) ?? '');
    if (major == null || minor == null || patch == null) return null;

    final preRelease = (match.group(4) ?? '').toLowerCase();
    final token = preRelease.isEmpty ? '' : preRelease.split('.').first;
    final build = preRelease.isEmpty
        ? null
        : int.tryParse(preRelease.split('.').length > 1
            ? preRelease.split('.')[1]
            : '');

    final channel = switch (token) {
      '' => ReleaseChannel.stable,
      'stable' => ReleaseChannel.stable,
      'beta' => ReleaseChannel.beta,
      'nightly' => ReleaseChannel.nightly,
      'dev' => ReleaseChannel.dev,
      _ => ReleaseChannel.dev,
    };

    return ParsedVersion(
      major: major,
      minor: minor,
      patch: patch,
      channel: channel,
      channelBuild: build,
    );
  }

  int compare(String left, String right) {
    final a = parse(left);
    final b = parse(right);

    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    final majorCmp = a.major.compareTo(b.major);
    if (majorCmp != 0) return majorCmp;

    final minorCmp = a.minor.compareTo(b.minor);
    if (minorCmp != 0) return minorCmp;

    final patchCmp = a.patch.compareTo(b.patch);
    if (patchCmp != 0) return patchCmp;

    final channelCmp = _stabilityRank(a.channel).compareTo(_stabilityRank(b.channel));
    if (channelCmp != 0) return channelCmp;

    return (a.channelBuild ?? 0).compareTo(b.channelBuild ?? 0);
  }

  bool isNewer({required String latest, required String current}) =>
      compare(latest, current) > 0;

  bool isCompatible({required String currentVersion, required String minSupported}) =>
      compare(currentVersion, minSupported) >= 0;

  int _stabilityRank(ReleaseChannel channel) => switch (channel) {
        ReleaseChannel.dev => 0,
        ReleaseChannel.nightly => 1,
        ReleaseChannel.beta => 2,
        ReleaseChannel.stable => 3,
      };
}
