/// Contract for memory / context-window providers.
///
/// Implementations persist conversation history and expose it to the
/// AI inference pipeline as a formatted prompt context.
///
/// The concrete implementation is [ContextWindowManager], which combines
/// short-term in-memory storage with long-term SQLite persistence.
///
/// Dependency rule: core/memory/ ← features/ (allowed)
///                  core/memory/ → native/   (forbidden)
abstract class MemoryProvider {
  /// Adds a message to the active session and persists it.
  ///
  /// [role] must be either `'user'` or `'assistant'`.
  Future<void> addMessage({required String role, required String content});

  /// Builds a prompt-ready context string from the current session window.
  String buildPromptContext();

  /// Clears the in-memory window and starts a new session.
  void startNewSession();

  /// Loads a previously stored session by [sessionId] into the window.
  Future<void> loadSession(String sessionId);

  /// The identifier of the currently active session.
  String get currentSessionId;

  // TODO(future): add summarize() to compress long histories into a summary
  //               token budget before feeding them to the model.
}
