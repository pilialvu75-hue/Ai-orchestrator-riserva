import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../workshop_build_lab.dart';
import '../workshop_build_source_snapshot.dart';
import '../workshop_stable_build_request_provider.dart';

/// A content-bound, generation-aware identity for a future durable build.
///
/// This helper is deliberately not wired to the production BuildLab yet.
/// The production scheduler must persist the chosen generation and source
/// fingerprint before dispatching a remote build. Recomputing it on every
/// poll would break crash recovery if project files change mid-build.
abstract final class WorkshopDurableBuildIdentity {
  /// Hashes only the bounded and excluded-file-filtered source snapshot.
  ///
  /// Paths and bytes are length-prefixed to avoid delimiter collisions.
  /// File order and UI request ids cannot influence the source fingerprint.
  static String sourceDigest(WorkshopBuildSourceSnapshot snapshot) {
    final files = snapshot.files.toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (files.isEmpty) {
      throw StateError('Cannot identify a durable build with empty source.');
    }

    final bytes = BytesBuilder(copy: false)
      ..add(utf8.encode('workshop-durable-source-v1:'));
    String? previousPath;
    for (final file in files) {
      final relative = file.relativePath;
      final segments = relative.split('/');
      if (relative.isEmpty ||
          relative.contains('\\') ||
          relative.startsWith('/') ||
          segments.any((part) => part.isEmpty || part == '.' || part == '..') ||
          previousPath == relative) {
        throw StateError('Unsafe or duplicate durable source path.');
      }
      previousPath = relative;
      final name = utf8.encode(relative);
      bytes
        ..add(utf8.encode('${name.length}:'))
        ..add(name)
        ..add(utf8.encode('${file.bytes.lengthInBytes}:'))
        ..add(file.bytes);
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }

  /// Distinct source changes AND distinct explicitly requested generations
  /// must produce different durable build identities.
  ///
  /// The caller is responsible for persisting [generation] at the start of
  /// the logical execution and reusing it when recovering an in-flight run.
  static String forBuild({
    required WorkshopBuildRequest request,
    required WorkshopBuildSourceSnapshot snapshot,
    required int generation,
  }) {
    if (generation < 1) {
      throw ArgumentError.value(
        generation,
        'generation',
        'must be a positive persisted build generation',
      );
    }
    final intent = WorkshopStableBuildRequestIdentity.forRequest(request);
    final source = sourceDigest(snapshot);
    final digest = sha256.convert(utf8.encode(
      'workshop-durable-build-v2:$intent:$source:$generation',
    ));
    return 'durable-v2-${digest.toString().substring(0, 40)}';
  }
}
