/// Persistent descriptor of a safe source snapshot captured from a verified
/// Workshop project.
///
/// The snapshot directory contains only allow-listed text/source files. It is
/// intentionally separate from the reusable-asset catalog so large source
/// contents are never stored in SharedPreferences.
final class WorkshopReuseSourceSnapshot {
  WorkshopReuseSourceSnapshot({
    required this.assetId,
    required this.rootPath,
    required List<String> files,
    required this.totalBytes,
    DateTime? createdAt,
  })  : createdAt = (createdAt ?? DateTime.now()).toUtc(),
        files = List<String>.unmodifiable(files);

  final String assetId;
  final String rootPath;
  final List<String> files;
  final int totalBytes;
  final DateTime createdAt;

  bool get isUsable =>
      assetId.trim().isNotEmpty &&
      rootPath.trim().isNotEmpty &&
      files.isNotEmpty &&
      totalBytes >= 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'assetId': assetId,
        'rootPath': rootPath,
        'files': files,
        'totalBytes': totalBytes,
        'createdAt': createdAt.toIso8601String(),
      };

  factory WorkshopReuseSourceSnapshot.fromJson(Map<String, dynamic> json) {
    final assetId = _requiredString(json, 'assetId');
    final rootPath = _requiredString(json, 'rootPath');
    final rawFiles = json['files'];
    final files = rawFiles is List
        ? rawFiles
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final totalBytes = json['totalBytes'] is num
        ? (json['totalBytes'] as num).toInt()
        : 0;
    final createdAt = DateTime.tryParse(
          json['createdAt']?.toString() ?? '',
        )?.toUtc() ??
        DateTime.now().toUtc();

    return WorkshopReuseSourceSnapshot(
      assetId: assetId,
      rootPath: rootPath,
      files: files,
      totalBytes: totalBytes < 0 ? 0 : totalBytes,
      createdAt: createdAt,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw FormatException('Reuse source snapshot $key is missing.');
    }
    return value;
  }
}

/// In-memory index that maps reusable asset IDs to their safe source snapshot.
final class WorkshopReuseSourceSnapshotIndex {
  WorkshopReuseSourceSnapshotIndex({
    Iterable<WorkshopReuseSourceSnapshot> initialSnapshots =
        const <WorkshopReuseSourceSnapshot>[],
  }) {
    for (final snapshot in initialSnapshots) {
      register(snapshot);
    }
  }

  final Map<String, WorkshopReuseSourceSnapshot> _snapshots =
      <String, WorkshopReuseSourceSnapshot>{};

  int get length => _snapshots.length;

  List<WorkshopReuseSourceSnapshot> get snapshots =>
      List<WorkshopReuseSourceSnapshot>.unmodifiable(_snapshots.values);

  void register(WorkshopReuseSourceSnapshot snapshot) {
    if (!snapshot.isUsable) {
      throw ArgumentError.value(
        snapshot.assetId,
        'snapshot',
        'Reusable source snapshot is not usable.',
      );
    }
    _snapshots[snapshot.assetId.trim()] = snapshot;
  }

  WorkshopReuseSourceSnapshot? forAsset(String assetId) =>
      _snapshots[assetId.trim()];

  bool removeForAsset(String assetId) =>
      _snapshots.remove(assetId.trim()) != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'snapshots': _snapshots.values
            .map((snapshot) => snapshot.toJson())
            .toList(growable: false),
      };

  factory WorkshopReuseSourceSnapshotIndex.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json['version'] != 1 || json['snapshots'] is! List) {
      return WorkshopReuseSourceSnapshotIndex();
    }

    final snapshots = <WorkshopReuseSourceSnapshot>[];
    for (final raw in json['snapshots'] as List) {
      if (raw is! Map) continue;
      try {
        final snapshot = WorkshopReuseSourceSnapshot.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (snapshot.isUsable) snapshots.add(snapshot);
      } catch (_) {
        // One corrupt source descriptor must not poison the entire index.
      }
    }

    return WorkshopReuseSourceSnapshotIndex(
      initialSnapshots: snapshots,
    );
  }
}
