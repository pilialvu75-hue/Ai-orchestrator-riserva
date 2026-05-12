/// A mutable, thread-local-ish context object shared among agents executing
/// within the same orchestration session.
///
/// [SharedContext] holds facts, intermediate results, and configuration that
/// multiple agents need to read or write during a collaborative task.  It is
/// **not** a global singleton; each orchestration session creates its own
/// instance and passes it explicitly to every agent it spawns.
///
/// Dependency rule:
///   core/agents/ defines [SharedContext]
///   features/ / plugins/ provide concrete implementations
///
/// Planned implementations:
/// - `InMemorySharedContext` — simple `Map`-backed context for single-session use.
/// - `PersistentSharedContext` — SQLite-backed context that survives app restarts.
/// - `DistributedSharedContext` — Redis / Firestore backend for multi-device runs.
abstract class SharedContext {
  /// Unique identifier for this orchestration session.
  String get sessionId;

  /// Reads the value stored under [key], or `null` if not present.
  T? get<T>(String key);

  /// Stores [value] under [key], overwriting any existing entry.
  void set<T>(String key, T value);

  /// Removes the entry for [key].  No-op if the key does not exist.
  void remove(String key);

  /// Returns `true` when [key] is present in the context.
  bool containsKey(String key);

  /// An unmodifiable view of all current context entries.
  Map<String, dynamic> get snapshot;

  /// Merges all entries from [other] into this context.
  ///
  /// Existing keys are overwritten if present in [other].
  void merge(Map<String, dynamic> other);

  /// Clears all entries and resets the context to its initial state.
  void clear();

  /// Persists the current context snapshot to durable storage.
  ///
  /// No-op for in-memory implementations.
  Future<void> persist();

  /// Restores context from durable storage using [sessionId].
  ///
  /// No-op for in-memory implementations.
  Future<void> restore();

  // TODO(future): add watch<T>(String key, void Function(T? old, T? newVal))
  //               to observe individual key changes reactively.
  // TODO(future): add versioning/conflict-resolution for distributed contexts.
}
