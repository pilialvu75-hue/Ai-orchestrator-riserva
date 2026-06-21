import 'dart:async';
import 'dart:convert';

typedef ForensicLogFn = void Function(String message);

const int kForensicWindowSize = 512;

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

String describeUtf8PayloadForensics({
  required String label,
  required String payload,
}) {
  final bytes = utf8.encode(payload);
  final headLength = bytes.length < kForensicWindowSize ? bytes.length : kForensicWindowSize;
  final tailStart = bytes.length > kForensicWindowSize ? bytes.length - kForensicWindowSize : 0;
  final head = bytes.take(headLength).toList(growable: false);
  final tail = bytes.skip(tailStart).toList(growable: false);

  String hexDump(List<int> input) =>
      input.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');

  return [
    '[$label] raw=$payload',
    '[$label] chars=${payload.length} bytes=${bytes.length}',
    '[$label] first_512_hex=${hexDump(head)}',
    '[$label] last_512_hex=${hexDump(tail)}',
  ].join('\n');
}
