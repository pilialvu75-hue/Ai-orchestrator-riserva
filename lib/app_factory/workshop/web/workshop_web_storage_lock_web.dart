import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator(JSObject _) implements JSObject {
  external _LockManager? get locks;
}

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(String name, JSFunction callback);
}

/// Origin-wide coordination between cooperating Aivexus tabs. Browsers without
/// Web Locks remain read-only, rather than relying on a racy localStorage lease.
Future<T> withWorkshopStorageLock<T>(
  String name,
  Future<T> Function() action,
) async {
  final locks = _navigator.locks;
  if (locks == null) {
    throw UnsupportedError(
      'Salvataggio sicuro non disponibile in questo browser.',
    );
  }
  late T result;
  Object? failure;
  StackTrace? failureStack;
  Future<JSAny?> execute() async {
    try {
      result = await action();
    } catch (error, stack) {
      // Preserve the original Dart error across the JS promise boundary.
      failure = error;
      failureStack = stack;
    }
    return null;
  }

  await locks.request(name, ((JSAny? _) => execute().toJS).toJS).toDart;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}
