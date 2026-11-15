import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../workshop_build_lab.dart';
import '../workshop_build_source_snapshot.dart';
import '../workshop_stable_build_request_provider.dart';
import 'workshop_durable_build_identity.dart';

/// A content-addressed reference to source bytes persisted before dispatch.
/// This opaque handle contains no raw project path, credentials or source text.
final class WorkshopDurableFrozenSourceHandle {
  const WorkshopDurableFrozenSourceHandle({
    required this.key,
    required this.intentId,
    required this.sourceSha256,
  });

  final String key;
  final String intentId;
  final String sourceSha256;
}

/// App-private disk store for a BOUNDED, immutable source snapshot.
///
/// This is an isolated building block, not yet wired to remote GitHub dispatch.
/// A future scheduler must:
/// 1. capture and validate source, then persist() and verify its handle;
/// 2. reserve a generation in the durable generation ledger;
/// 3. persist WAITING_EXTERNAL before dispatching the same frozen bytes;
/// 4. recover() those bytes after restart, never recapture modified workspace.
///
/// The caller MUST supply an app-private root outside the project workspace.
/// The namespace provides deterministic separation, NOT authentication.
/// All operations are serialized within one isolate; a single scheduler
/// authority is required before using this in multi-isolate production.
final class WorkshopDurableFrozenSourceStore {
  WorkshopDurableFrozenSourceStore({required Directory root})
      : _root = Directory(p.normalize(p.absolute(root.path)));

  static const int maxFiles = 1024;
  static const int maxFileBytes = 8 * 1024 * 1024;
  static const int maxSourceBytes = 24 * 1024 * 1024;
  static const int _maxArchiveBytes = 27 * 1024 * 1024;
  static const int _maxPathBytes = 2048;
  static final Uint8List _magic =
      Uint8List.fromList(utf8.encode('AIVEXUS-FROZEN-SOURCE-V1\n'));
  static Future<void> _mutationTail = Future<void>.value();

  final Directory _root;

  Future<WorkshopDurableFrozenSourceHandle> persist({
    required WorkshopBuildRequest request,
    required WorkshopBuildSourceSnapshot source,
    required String namespace,
  }) =>
      _serialize(() async {
        await _validateRoot(request);
        final handle = _handle(request, source, namespace);
        final file = _file(handle.key);
        if (await _existsWithoutSymlink(file)) {
          // Never replace a file for an already-issued content identity.
          await _readChecked(request, handle, file);
          return handle;
        }

        final bytes = _encode(source);
        if (bytes.lengthInBytes > _maxArchiveBytes) {
          throw StateError('Frozen Cantiere snapshot exceeds storage limit.');
        }
        final partial = File(file.path + '.partial');
        if (await FileSystemEntity.type(partial.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('Frozen Cantiere partial file is a symbolic link.');
        }
        try {
          await partial.writeAsBytes(bytes, flush: true);
          await partial.rename(file.path);
          await _readChecked(request, handle, file);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
        return handle;
      });

  /// A missing or corrupted persisted snapshot is an explicit error. It must
  /// never silently fall back to capturing the current workspace.
  Future<WorkshopBuildSourceSnapshot> recover({
    required WorkshopBuildRequest request,
    required WorkshopDurableFrozenSourceHandle handle,
    required String namespace,
  }) =>
      _serialize(() async {
        await _validateRoot(request);
        _validateHandle(request, handle, namespace);
        return _readChecked(request, handle, _file(handle.key));
      });

  static WorkshopDurableFrozenSourceHandle _handle(
    WorkshopBuildRequest request,
    WorkshopBuildSourceSnapshot source,
    String namespace,
  ) {
    final normalizedNamespace = namespace.trim();
    if (normalizedNamespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'is required');
    }
    final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
    final digest = WorkshopDurableBuildIdentity.sourceDigest(source);
    final keyDigest = sha256.convert(utf8.encode(
      'aivexus-frozen-source-v1:' +
          normalizedNamespace + ':' + intent + ':' + digest,
    )).toString();
    return WorkshopDurableFrozenSourceHandle(
      key: 'frozen-v1-' + keyDigest.substring(0, 40),
      intentId: intent,
      sourceSha256: digest,
    );
  }

  static void _validateHandle(
    WorkshopBuildRequest request,
    WorkshopDurableFrozenSourceHandle handle,
    String namespace,
  ) {
    final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
    if (intent != handle.intentId ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(handle.sourceSha256) ||
        !RegExp(r'^frozen-v1-[a-f0-9]{40}$').hasMatch(handle.key)) {
      throw StateError('Invalid frozen Cantiere source reference.');
    }
    final digest = sha256.convert(utf8.encode(
      'aivexus-frozen-source-v1:' +
          namespace.trim() + ':' + intent + ':' + handle.sourceSha256,
    )).toString();
    if (namespace.trim().isEmpty ||
        handle.key != 'frozen-v1-' + digest.substring(0, 40)) {
      throw StateError('Frozen Cantiere source namespace does not match.');
    }
  }

  Future<void> _validateRoot(WorkshopBuildRequest request) async {
    final workspace = p.normalize(p.absolute(request.projectPath));
    final root = _root.path;
    if (root == workspace ||
        p.isWithin(workspace, root) ||
        p.isWithin(root, workspace)) {
      throw StateError(
        'Frozen source storage must be outside the generated workspace.',
      );
    }
    final existing = await FileSystemEntity.type(root, followLinks: false);
    if (existing == FileSystemEntityType.link) {
      throw StateError('Frozen source root cannot be a symbolic link.');
    }
    await _root.create(recursive: true);
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Frozen source root is not a directory.');
    }
  }

  File _file(String key) => File(p.join(_root.path, key + '.avxf'));

  static Future<bool> _existsWithoutSymlink(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('Frozen Cantiere snapshot must not be a symlink.');
    }
    return type == FileSystemEntityType.file;
  }

  static Uint8List _encode(WorkshopBuildSourceSnapshot snapshot) {
    if (snapshot.files.isEmpty || snapshot.files.length > maxFiles) {
      throw StateError('Invalid frozen Cantiere source file count.');
    }
    final files = snapshot.files.toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    final builder = BytesBuilder(copy: false)..add(_magic);
    void addUint32(int value) {
      final data = ByteData(4)..setUint32(0, value, Endian.big);
      builder.add(data.buffer.asUint8List());
    }

    addUint32(files.length);
    var total = 0;
    for (final file in files) {
      final path = utf8.encode(file.relativePath);
      final size = file.bytes.lengthInBytes;
      if (path.isEmpty || path.length > _maxPathBytes ||
          size > maxFileBytes || total + size > maxSourceBytes) {
        throw StateError('Frozen Cantiere source exceeds bounded limits.');
      }
      total += size;
      addUint32(path.length);
      builder.add(path);
      addUint32(size);
      builder.add(file.bytes);
    }
    return builder.takeBytes();
  }

  static WorkshopBuildSourceSnapshot _decode(
    Uint8List bytes,
    String rootPath,
  ) {
    if (bytes.lengthInBytes < _magic.length + 4 ||
        bytes.lengthInBytes > _maxArchiveBytes) {
      throw const FormatException('Invalid frozen source archive length.');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const FormatException('Invalid frozen source archive version.');
      }
    }
    var offset = _magic.length;
    int getUint32() {
      if (offset + 4 > bytes.lengthInBytes) {
        throw const FormatException('Truncated frozen source integer.');
      }
      final result = ByteData.sublistView(
        bytes, offset, offset + 4,
      ).getUint32(0, Endian.big);
      offset += 4;
      return result;
    }

    final count = getUint32();
    if (count < 1 || count > maxFiles) {
      throw const FormatException('Invalid frozen source file count.');
    }
    final files = <WorkshopBuildSourceFile>[];
    var totalBytes = 0;
    for (var i = 0; i < count; i++) {
      final pathLength = getUint32();
      if (pathLength < 1 || pathLength > _maxPathBytes ||
          pathLength > bytes.lengthInBytes - offset) {
        throw const FormatException('Invalid frozen source relative path.');
      }
      final path = utf8.decode(
        bytes.sublist(offset, offset + pathLength),
        allowMalformed: false,
      );
      offset += pathLength;
      final size = getUint32();
      if (size > maxFileBytes || size > bytes.lengthInBytes - offset ||
          totalBytes + size > maxSourceBytes) {
        throw const FormatException('Invalid frozen source file size.');
      }
      final payload = Uint8List.fromList(
        bytes.sublist(offset, offset + size),
      );
      offset += size;
      totalBytes += size;
      files.add(WorkshopBuildSourceFile(relativePath: path, bytes: payload));
    }
    if (offset != bytes.lengthInBytes) {
      throw const FormatException('Trailing untrusted frozen source data.');
    }
    return WorkshopBuildSourceSnapshot(
      rootPath: rootPath,
      files: List<WorkshopBuildSourceFile>.unmodifiable(files),
      totalBytes: totalBytes,
    );
  }

  static Future<WorkshopBuildSourceSnapshot> _readChecked(
    WorkshopBuildRequest request,
    WorkshopDurableFrozenSourceHandle handle,
    File file,
  ) async {
    if (!await _existsWithoutSymlink(file)) {
      throw StateError('Frozen Cantiere source is missing.');
    }
    if (await file.length() > _maxArchiveBytes) {
      throw StateError('Frozen Cantiere source is larger than the limit.');
    }
    try {
      final restored = _decode(
        await file.readAsBytes(),
        request.projectPath,
      );
      final actual = WorkshopDurableBuildIdentity.sourceDigest(restored);
      if (actual != handle.sourceSha256) {
        throw StateError('Frozen Cantiere source digest differs.');
      }
      return restored;
    } catch (_) {
      throw StateError('Frozen Cantiere source is corrupt or mismatched.');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
