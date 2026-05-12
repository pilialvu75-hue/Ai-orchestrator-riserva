import 'package:ai_orchestrator/core/agents/shared_context.dart';

/// Simple in-memory implementation of [SharedContext].
///
/// All data is stored in a [Map] and lost when the session ends.  This is the
/// default implementation used by [SequentialPlanningStrategy] for single-run
/// orchestration sessions.
///
/// For persistence across app restarts, replace with a SQLite-backed context
/// (see [SharedContext] documentation for the planned `PersistentSharedContext`).
class InMemorySharedContext implements SharedContext {
  InMemorySharedContext({required String sessionId})
      : _sessionId = sessionId;

  final String _sessionId;
  final Map<String, dynamic> _store = {};

  @override
  String get sessionId => _sessionId;

  @override
  T? get<T>(String key) {
    final value = _store[key];
    if (value is T) return value;
    return null;
  }

  @override
  void set<T>(String key, T value) {
    _store[key] = value;
  }

  @override
  void remove(String key) {
    _store.remove(key);
  }

  @override
  bool containsKey(String key) => _store.containsKey(key);

  @override
  Map<String, dynamic> get snapshot => Map.unmodifiable(_store);

  @override
  void merge(Map<String, dynamic> other) {
    _store.addAll(other);
  }

  @override
  void clear() {
    _store.clear();
  }

  @override
  Future<void> persist() async {
    // In-memory context does not persist across sessions.
  }

  @override
  Future<void> restore() async {
    // Nothing to restore for an in-memory context.
  }
}
