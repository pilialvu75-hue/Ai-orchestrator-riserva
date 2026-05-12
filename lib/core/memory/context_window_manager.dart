import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/memory/memory_provider.dart';
import 'package:uuid/uuid.dart';

/// Represents a single message in the conversation context.
class ContextMessage {
  const ContextMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  final String id;
  final String sessionId;

  /// Either `'user'` or `'assistant'`.
  final String role;
  final String content;
  final int timestamp;

  Map<String, dynamic> toMap() => {
        AppConstants.colId: id,
        AppConstants.colSessionId: sessionId,
        AppConstants.colRole: role,
        AppConstants.colContent: content,
        AppConstants.colTimestamp: timestamp,
      };

  static ContextMessage fromMap(Map<String, dynamic> map) => ContextMessage(
        id: map[AppConstants.colId] as String,
        sessionId: map[AppConstants.colSessionId] as String,
        role: map[AppConstants.colRole] as String,
        content: map[AppConstants.colContent] as String,
        timestamp: map[AppConstants.colTimestamp] as int,
      );
}

/// Manages both short-term (in-memory) and long-term (SQLite) conversation
/// context for the local AI inference pipeline.
///
/// Short-term: keeps the last [AppConstants.contextWindowMaxMessages] turns in
/// an in-memory list so they can be fed directly to the model prompt.
///
/// Long-term: every message is persisted to [DatabaseHelper] so the full
/// history survives app restarts and can be used to build user-preference
/// summaries.
class ContextWindowManager implements MemoryProvider {
  ContextWindowManager({required this.databaseHelper});

  final DatabaseHelper databaseHelper;

  final List<ContextMessage> _window = [];
  String _currentSessionId = const Uuid().v4();

  /// The active session identifier.
  @override
  String get currentSessionId => _currentSessionId;

  /// The current in-memory context window (up to
  /// [AppConstants.contextWindowMaxMessages] items).
  List<ContextMessage> get window => List.unmodifiable(_window);

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Adds a message to the context window and persists it to the database.
  @override
  Future<void> addMessage({
    required String role,
    required String content,
  }) async {
    final msg = ContextMessage(
      id: const Uuid().v4(),
      sessionId: _currentSessionId,
      role: role,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _window.add(msg);
    _trimWindow();
    await databaseHelper.insertChatMessage(msg.toMap());
  }

  /// Builds the prompt context string from the current window, formatted as
  /// alternating `User:` / `Assistant:` lines.
  @override
  String buildPromptContext() {
    return _window.map((m) {
      final label = m.role == 'user' ? 'User' : 'Assistant';
      return '$label: ${m.content}';
    }).join('\n');
  }

  /// Starts a new conversation session, clearing the in-memory window.
  @override
  void startNewSession() {
    _currentSessionId = const Uuid().v4();
    _window.clear();
  }

  /// Loads the last [AppConstants.contextWindowMaxMessages] messages from the
  /// database for [sessionId] into the in-memory window.
  @override
  Future<void> loadSession(String sessionId) async {
    _currentSessionId = sessionId;
    _window.clear();
    final rows = await databaseHelper.getChatMessages(sessionId);
    for (final row in rows) {
      _window.add(ContextMessage.fromMap(row));
    }
    _trimWindow();
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  void _trimWindow() {
    while (_window.length > AppConstants.contextWindowMaxMessages) {
      _window.removeAt(0);
    }
  }
}
