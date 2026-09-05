/// Returns the task's result while allowing callers to keep a recovered queue
/// tail separately. A failed generation must remain visible to its consumer.
Future<void> runSerialInferenceTask(
  Future<void> previous,
  Future<void> Function() action,
) async {
  try {
    await previous;
  } catch (_) {
    // A previous request must not prevent subsequent requests from running.
  }
  await action();
}
