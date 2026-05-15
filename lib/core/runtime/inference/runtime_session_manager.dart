import 'package:ai_orchestrator/core/runtime/inference/runtime_session.dart';

class RuntimeSessionManager {
  RuntimeSession? _activeSession;

  RuntimeSession? get activeSession => _activeSession;

  String? get activeSessionId => _activeSession?.sessionId;

  RuntimeSession startSession(String sessionId) {
    _activeSession?.cancellationToken.cancel();
    final session = RuntimeSession(sessionId: sessionId);
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
