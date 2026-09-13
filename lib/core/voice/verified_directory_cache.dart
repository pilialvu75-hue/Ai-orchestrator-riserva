import 'dart:io';

/// Reuses a successful integrity check only within this process while the
/// complete directory metadata stays unchanged. Never persists trust to disk.
final class VerifiedDirectoryCache {
  VerifiedDirectoryCache(this._verify);
  final Future<Map<String, String>?> Function(String) _verify;
  final _entries = <String, _VerifiedEntry>{};
  final _pending = <String, Future<Map<String, String>?>>{};
  int _revision = 0;

  void clear() {
    _revision++;
    _entries.clear();
  }

  Future<Map<String, String>?> get(String root) async {
    final pending = _pending[root];
    if (pending != null) return pending;
    final operation = _get(root, _revision);
    _pending[root] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pending[root], operation)) _pending.remove(root);
    }
  }

  Future<Map<String, String>?> _get(String root, int revision) async {
    final before = await _snapshot(root);
    if (before == null || revision != _revision) {
      _entries.remove(root);
      return null;
    }
    final cached = _entries[root];
    if (cached != null && cached.snapshot == before) return cached.paths;
    _entries.remove(root);
    final paths = await _verify(root);
    if (paths == null || revision != _revision) return null;
    final after = await _snapshot(root);
    if (after != before || revision != _revision) return null;
    final immutable = Map<String, String>.unmodifiable(paths);
    _entries[root] = _VerifiedEntry(before, immutable);
    return immutable;
  }

  Future<String?> _snapshot(String root) async {
    try {
      final rows = <String>[];
      Future<void> record(FileSystemEntity entity) async {
        if (entity is Link) throw const FileSystemException('Linked asset');
        final stat = await entity.stat();
        if (stat.type == FileSystemEntityType.notFound) {
          throw const FileSystemException('Missing asset');
        }
        rows.add('${entity.path}\u0000${stat.type}\u0000${stat.size}\u0000'
            '${stat.modified.microsecondsSinceEpoch}\u0000'
            '${stat.changed.microsecondsSinceEpoch}\u0000${stat.mode}');
      }
      final directory = Directory(root);
      await record(directory);
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        await record(entity);
      }
      rows.sort();
      return rows.join('\n');
    } on FileSystemException {
      return null;
    }
  }
}

final class _VerifiedEntry {
  const _VerifiedEntry(this.snapshot, this.paths);
  final String snapshot;
  final Map<String, String> paths;
}
