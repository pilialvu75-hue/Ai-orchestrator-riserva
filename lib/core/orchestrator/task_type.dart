/// Classifies the kind of work a user input requires.
enum TaskType {
  /// General conversational exchange handled by an AI provider.
  chat,

  /// A device/system command (e.g. "apri", "chiama", "lancia").
  command,

  /// A low-level system operation.
  system,
}
