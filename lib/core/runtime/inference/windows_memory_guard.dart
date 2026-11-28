import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

class WindowsMemoryPressure implements Exception {
  static const message =
      'Local inference stopped: Windows system commit limit exhausted. '
      'Free memory or select a smaller model.';
  @override
  String toString() => message;
}

/// Owns a sampling lease only during one model load or generation.
/// Existing routes tolerate unavailable telemetry; future partial offload
/// must separately require a known fresh RAM/VRAM admission budget.
class WindowsMemoryGuard {
  WindowsMemoryGuard(this.monitor, {required this.abort});
  final ResourceMonitor monitor;
  final void Function() abort;
  bool _active = false;
  bool _tripped = false;
  bool get tripped => _tripped;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    monitor.addListener(_onSample);
    monitor.retain();
    await monitor.sample();
    check();
  }

  void _onSample() {
    if (!_active || _tripped) return;
    final reading = monitor.latest;
    // Low physical RAM is advisory. Do not kill a working GPU engine
    // merely because the diagnostic 5% threshold has been crossed.
    if (reading?.windowsCommitExhausted != true) return;
    _tripped = true;
    abort();
  }

  void check() {
    if (_tripped) throw WindowsMemoryPressure();
  }

  void release() {
    if (!_active) return;
    _active = false;
    monitor.removeListener(_onSample);
    monitor.release();
  }
}
