import 'package:uuid/uuid.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_checkpoint_snapshot_store.dart';
import 'chat_session_store.dart';

/// Device-local, single-profile identity for opt-in HYBRID experiments.
///
/// This is a persisted installation identity in OS-protected storage,
/// combined with an existing, non-trashed local chat session. It requires no
/// network and never inspects message text. It is *not* a login, a remote
/// authenticated principal, a multi-user access control system or a
/// cross-device identity. Do NOT use it to authorize Cloud data sharing.
///
/// The HYBRID relay needs an explicit callable owner/session gate. This
/// adapter provides one for a single local-device profile while the app has
/// no signed-in account identity. Do not silently wire it into regular Chat.
final class HybridLocalSessionAuthorizer {
  HybridLocalSessionAuthorizer({
    required HybridProtectedSnapshotBackend backend,
    required ChatSessionStore sessions,
  })  : _backend = backend,
        _sessions = sessions;

  static const String _identityKey = 'hybrid_local_device_owner_v1';
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  final HybridProtectedSnapshotBackend _backend;
  final ChatSessionStore _sessions;
  Future<void> _tail = Future<void>.value();

  /// Explicitly register this installation for a local HYBRID pilot.
  /// Never called automatically while resolving or reading normal Chat.
  Future<String> initializeLocalOwner() => _serialize(() async {
        final existing = await _backend.read(_identityKey);
        if (existing != null) {
          if (!_uuidPattern.hasMatch(existing)) {
            throw StateError('Invalid protected HYBRID local identity');
          }
          return existing;
        }
        final ownerId = const Uuid().v4();
        await _backend.write(_identityKey, ownerId);
        if (await _backend.read(_identityKey) != ownerId) {
          throw StateError('HYBRID local identity was not durably confirmed');
        }
        return ownerId;
      });

  /// Never creates an owner as a side effect of an authorization attempt.
  /// A denied request must remain denied even after process restart.
  Future<bool> authorizeOwnerSession(String ownerId, String sessionId) async {
    if (!_uuidPattern.hasMatch(ownerId) ||
        sessionId.trim().isEmpty ||
        sessionId.trim() != sessionId ||
        sessionId.length > 256) {
      return false;
    }
    try {
      final savedOwner = await _backend.read(_identityKey);
      if (savedOwner == null ||
          !_uuidPattern.hasMatch(savedOwner) ||
          savedOwner != ownerId) {
        return false;
      }
      return await _sessions.hasUsableSession(sessionId);
    } catch (_) {
      // Protected storage or SQLite failures are not authorization.
      return false;
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return pending;
  }
}
