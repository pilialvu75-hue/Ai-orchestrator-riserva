import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'workshop_library_submission.dart';

/// One exact payload file prepared for Module Library intake.
///
/// The path is relative to the reusable payload root represented by the
/// canonical archive document. Bytes are copied defensively so the digest
/// cannot change after construction.
final class WorkshopLibraryIntakePayloadFile {
  WorkshopLibraryIntakePayloadFile({
    required String path,
    required List<int> bytes,
  })  : path = path.trim(),
        bytes = List<int>.unmodifiable(bytes);

  final String path;
  final List<int> bytes;
}

/// Deterministic transport artifact containing the real payload bytes that
/// correspond to an already accepted [WorkshopLibraryIntakeSubmission].
///
/// V1 deliberately uses a canonical JSON archive. The accepted manifest must
/// therefore declare `payload.type=archive`, a safe path below `payload/`, and
/// the same SHA-256 as the canonical [payloadJson]. The private Module Library
/// can later materialize [payloadJson] at [payloadPath] and its existing intake
/// pipeline will verify the exact same digest before normalization.
///
/// This class remains transport-free: it neither reads credentials nor writes
/// GitHub or the Library.
final class WorkshopLibraryIntakeBundle {
  const WorkshopLibraryIntakeBundle._({
    required this.pin,
    required this.manifestPath,
    required this.payloadPath,
    required this.manifest,
    required this.payloadJson,
    required this.payloadSha256,
    required this.bundleJson,
    required this.bundleSha256,
  });

  final String pin;
  final String manifestPath;
  final String payloadPath;
  final Map<String, Object?> manifest;

  /// Canonical UTF-8 JSON string whose SHA-256 is [payloadSha256].
  ///
  /// Keeping the canonical representation as a string avoids requiring a
  /// cross-language executor to reproduce Dart map serialization semantics.
  final String payloadJson;
  final String payloadSha256;

  /// Canonical complete bundle handed to a later outbox/executor boundary.
  final String bundleJson;
  final String bundleSha256;

  static String computePayloadSha256(
    Iterable<WorkshopLibraryIntakePayloadFile> files,
  ) {
    final payloadJson = _canonicalPayloadJson(files);
    return sha256.convert(utf8.encode(payloadJson)).toString();
  }

  factory WorkshopLibraryIntakeBundle.build({
    required WorkshopLibraryIntakeSubmission submission,
    required Iterable<WorkshopLibraryIntakePayloadFile> files,
  }) {
    final normalizedFiles = files.toList(growable: false);
    final payloadJson = _canonicalPayloadJson(normalizedFiles);
    final payloadSha256 = sha256.convert(utf8.encode(payloadJson)).toString();
    final expectedPayloadSha256 = submission.payloadSha256.trim().toLowerCase();

    if (payloadSha256 != expectedPayloadSha256) {
      throw StateError(
        'Library payload digest mismatch: expected '
        '$expectedPayloadSha256, computed $payloadSha256.',
      );
    }

    final manifestPayload = submission.manifest['payload'];
    if (manifestPayload is! Map) {
      throw StateError('Library manifest payload descriptor is missing.');
    }
    final payloadType = manifestPayload['type']?.toString().trim();
    final payloadPath = manifestPayload['path']?.toString().trim() ?? '';
    final manifestPayloadSha256 =
        manifestPayload['sha256']?.toString().trim().toLowerCase() ?? '';
    if (payloadType != 'archive') {
      throw StateError('Library intake bundle v1 requires payload.type=archive.');
    }
    if (!payloadPath.startsWith('payload/') || !_isSafePayloadPath(payloadPath)) {
      throw StateError(
        'Library intake bundle archive path must stay below payload/.',
      );
    }
    if (manifestPayloadSha256 != payloadSha256) {
      throw StateError(
        'Library manifest payload.sha256 does not match the canonical payload.',
      );
    }

    final bundle = <String, Object?>{
      'schema': 'ai-orchestrator.library-intake-bundle.v1',
      'pin': submission.pin,
      'manifest_path': submission.manifestPath,
      'payload_path': payloadPath,
      'payload_sha256': payloadSha256,
      'payload_json': payloadJson,
      'manifest': submission.manifest,
    };
    final bundleJson = jsonEncode(bundle);
    final bundleSha256 = sha256.convert(utf8.encode(bundleJson)).toString();

    return WorkshopLibraryIntakeBundle._(
      pin: submission.pin,
      manifestPath: submission.manifestPath,
      payloadPath: payloadPath,
      manifest: Map<String, Object?>.unmodifiable(submission.manifest),
      payloadJson: payloadJson,
      payloadSha256: payloadSha256,
      bundleJson: bundleJson,
      bundleSha256: bundleSha256,
    );
  }

  static String _canonicalPayloadJson(
    Iterable<WorkshopLibraryIntakePayloadFile> files,
  ) {
    final sorted = files.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    if (sorted.isEmpty) {
      throw ArgumentError('Library intake payload must contain at least one file.');
    }

    final seen = <String>{};
    final encodedFiles = <Map<String, Object?>>[];
    for (final file in sorted) {
      final path = file.path.trim();
      if (!_isSafePayloadPath(path)) {
        throw ArgumentError.value(path, 'path', 'Unsafe Library payload path.');
      }
      if (!seen.add(path)) {
        throw ArgumentError.value(path, 'path', 'Duplicate Library payload path.');
      }
      if (file.bytes.any((value) => value < 0 || value > 255)) {
        throw ArgumentError.value(path, 'bytes', 'Payload bytes must be in 0..255.');
      }

      encodedFiles.add(<String, Object?>{
        'path': path,
        'content_base64': base64Encode(file.bytes),
      });
    }

    return jsonEncode(<String, Object?>{
      'schema': 'ai-orchestrator.library-intake-payload.v1',
      'files': encodedFiles,
    });
  }

  static bool _isSafePayloadPath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('~') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.contains('\u0000')) {
      return false;
    }

    final segments = path.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      return false;
    }

    final lowerSegments = segments.map((segment) => segment.toLowerCase()).toList();
    if (lowerSegments.any(
      (segment) => const <String>{
        '.git',
        '.dart_tool',
        'build',
        'node_modules',
      }.contains(segment),
    )) {
      return false;
    }

    final fileName = lowerSegments.last;
    if (fileName == '.env' ||
        fileName == 'key.properties' ||
        fileName == 'keystore.properties' ||
        fileName == 'local.properties' ||
        fileName.endsWith('.jks') ||
        fileName.endsWith('.keystore') ||
        fileName.endsWith('.p12') ||
        fileName.endsWith('.pfx') ||
        fileName.endsWith('.pem') ||
        fileName.endsWith('.key')) {
      return false;
    }

    return true;
  }
}
