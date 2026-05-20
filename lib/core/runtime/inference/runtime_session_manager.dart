import 'package:ai_orchestrator/core/runtime/inference/runtime_session.dart';
import 'package:flutter/foundation.dart';

class RuntimeSessionManager {
  RuntimeSession? _activeSession;
  static int _sessionCreateCount = 0;

  RuntimeSession? get activeSession => _activeSession;

  String? get activeSessionId => _activeSession?.sessionId;

  RuntimeSession startSession(String sessionId) {
    if (_activeSession != null && _activeSession!.sessionId == sessionId) {
      debugPrint(
        '[ENTRY_REENTRANCY_BLOCK] scope=runtime_session_manager session=$sessionId existing=${_activeSession.hashCode.toRadixString(16)}',
      );
    }
    _activeSession?.cancellationToken.cancel();
    final session = RuntimeSession(sessionId: sessionId);
    _sessionCreateCount++;
    debugPrint(
      '[RUNTIME_LOOKUP] session=$sessionId stage=cancellation_token_create token=${session.cancellationToken.hashCode.toRadixString(16)} session_create_count=$_sessionCreateCount',
    );
    _activeSession = session;
    return session;
  }

  void cancel(String sessionId) {
    final activeSession = _activeSession;
    if (activeSession == null || activeSession.sessionId != sessionId) return;
    activeSession.cancellationToken.cancel();
  }

  void complete(RuntimeSession session) {
    if (identical(_activeSession, session)) {
      _activeSession = null;
    }
  }
}
