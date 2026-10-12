import 'dart:async';

/// VM adapter for tests. Browser writers use the origin-wide Web Locks API.
final Map<String, Future<void>> _pending = <String, Future<void>>{};

Future<T> withWorkshopStorageLock<T>(
  String name,
  Future<T> Function() action,
) async {
  final previous = _pending[name] ?? Future<void>.value();
  final completed = Completer<void>();
  _pending[name] = completed.future;
  await previous;
  try {
    return await action();
  } finally {
    completed.complete();
    if (identical(_pending[name], completed.future)) _pending.remove(name);
  }
}
