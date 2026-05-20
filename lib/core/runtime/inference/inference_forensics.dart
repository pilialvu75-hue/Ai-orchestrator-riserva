import 'dart:async';

typedef ForensicLogFn = void Function(String message);

Future<T> runInferenceGuarded<T>({
  required String scope,
  required Future<T> Function() action,
  required ForensicLogFn log,
  void Function(Object error, StackTrace stackTrace)? onError,
}) {
  final completer = Completer<T>();
  runZonedGuarded(
    () async {
      try {
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (error, stackTrace) {
        log('[ZONE_UNCAUGHT] scope=$scope error=$error stack=$stackTrace');
        onError?.call(error, stackTrace);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
        rethrow;
      }
    },
    (error, stackTrace) {
      log('[ZONE_UNCAUGHT] scope=$scope error=$error stack=$stackTrace');
      onError?.call(error, stackTrace);
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );
  return completer.future;
}
