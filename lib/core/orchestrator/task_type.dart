/// Classifies the kind of work a user input requires.
enum TaskType {
  /// General conversational exchange handled by an AI provider.
  chat,

  /// A device/system command (e.g. "apri", "chiama", "lancia").
  command,

  /// A low-level system operation.
  system,

  /// A complex multi-step goal that requires TaskWeaver-style planning:
  /// the goal is decomposed into a [Plan] and executed step by step.
  plan,

  /// A coding or code-analysis task (generation, debugging, refactoring).
  coding,
}
