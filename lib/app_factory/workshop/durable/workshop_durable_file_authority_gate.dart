import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Opt-in filesystem gate for ONE local durable scheduler mutation at a time.
///
/// An exclusive create is atomic on a supported local filesystem, including
/// across Dart isolates and separate OS processes. This is deliberately NOT a
/// standalone distributed lease: there is no clock-based expiry, stealing,
/// automatic orphan cleanup, or production wiring.
///
/// Use a pre-existing, application-private LOCAL directory that is not shared
/// over a network filesystem. Every actor touching the same durable stores
/// must use the same directory and scope, and must await all side effects
/// before returning from [run]. Cross-process crash/restart acceptance tests
/// and a single authoritative scheduler are still required for production.
final class WorkshopDurableFileAuthorityGate {
  WorkshopDurableFileAuthorityGate({
    required Directory privateRoot,
    required String schedulerScope,
  })  : _privateRoot = privateRoot.absolute,
        _scope = _requireScope(schedulerScope);

  final Directory _privateRoot;
  final String _scope;

  /// For diagnostics only. Never delete an occupied or orphaned gate blindly.
  String get lockPath => p.join(
        _privateRoot.path,
        '.workshop-durable-authority-${sha256.convert(utf8.encode(_scope))}.lock',
      );

  /// Fails closed when another owner (or an orphan after process death) holds
  /// the gate. It NEVER retries an ambiguous external action on its own.
  ///
  /// The gate deliberately stays on disk if writing its owner record fails.
  /// After a process crash it also remains: manual reconciliation is required
  /// before any owner can resume. No call to this method removes an orphan.
  Future<T> run<T>(Future<T> Function() action) async {
    final rootType = await FileSystemEntity.type(
      _privateRoot.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw StateError(
        'Durable scheduler authority requires an existing private directory.',
      );
    }

    final random = Random.secure();
    final owner = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
    final ownedContent = 'workshop-durable-authority-v1:$owner\n';
    final lock = File(lockPath);

    try {
      await lock.create(exclusive: true);
    } on PathExistsException {
      throw StateError(
        'Durable scheduler already owned or orphaned. '
        'Reconcile the checkpoint before manual recovery.',
      );
    }

    var ownerPersisted = false;
    try {
      // Exclusive creation has already established ownership. A failed owner
      // write deliberately leaves the gate occupied instead of guessing.
      await lock.writeAsString(ownedContent, flush: true);
      ownerPersisted = true;
      return await action();
    } finally {
      if (ownerPersisted) {
        // Never delete a replaced or tampered lock. If we cannot prove the
        // exact owner, keep the build blocked and require reconciliation.
        if (await lock.readAsString() != ownedContent) {
          throw StateError('Durable scheduler authority owner changed.');
        }
        await lock.delete();
      }
    }
  }

  static String _requireScope(String scope) {
    final normalized = scope.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(scope, 'schedulerScope', 'is required');
    }
    return normalized;
  }
}
