/// Coalesces probes and retains usable results. Transient failures can be
/// retried by a later request, without polling or delaying the current one.
final class WindowsGpuProbeCache {
  WindowsGpuProbeCache({Duration Function()? now,
      this.retryDelay = const Duration(seconds: 30)})
      : _now = now ?? _clock();
  final Duration Function() _now;
  final Duration retryDelay;
  Future<String?>? _pending;
  String? _value;
  Duration? _retryAt;

  Future<String?> get(Future<String?> Function() probe,
      {required bool Function(String) usable}) {
    if (_pending != null) return _pending!;
    if (_value != null && usable(_value!)) return Future.value(_value);
    if (_retryAt != null && _now() < _retryAt!) return Future.value(_value);
    final operation = Future<String?>.sync(probe).then((value) {
      _value = value;
      _retryAt = value != null && usable(value) ? null : _now() + retryDelay;
      return value;
    }, onError: (Object error, StackTrace stack) {
      _value = null;
      _retryAt = _now() + retryDelay;
      return null;
    }).whenComplete(() { _pending = null; });
    _pending = operation;
    return operation;
  }
  static Duration Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }
}
