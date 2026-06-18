/// Classifica il tipo di lavoro richiesto dall'input utente.
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

  /// Una richiesta di ricerca web ("cerca", "search", "notizie", ecc.).
  /// In modalità LOCAL utilizza il tool di ricerca web e poi passa i risultati
  /// al modello locale; in modalità CLOUD/HYBRID può ancora essere inoltrata
  /// ai provider cloud se necessario.
  webSearch,
}
