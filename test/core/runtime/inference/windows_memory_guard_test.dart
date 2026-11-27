import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_memory_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const critical = <Object?, Object?>{
    'windowsSample': true,
    'totalBytes': 16784617472,
    'availableBytes': 13742080,
  };
  const healthy = <Object?, Object?>{
    'windowsSample': true,
    'totalBytes': 16 * 1024 * 1024 * 1024,
    'availableBytes': 4 * 1024 * 1024 * 1024,
  };

  test('preflight rejects owner critical RAM sample before runtime startup',
      () async {
    final monitor = ResourceMonitor(sampler: () async => critical, logger: (_) {});
    addTearDown(monitor.dispose);
    final runtime = ResidentCompletionRuntime(windowsResources: monitor);
    addTearDown(runtime.close);
    await expectLater(runtime.prepare(
      executable: 'must-not-start.exe', modelPath: 'unused.gguf',
      sessionId: 'preflight', threads: 2,
    ), throwsA(isA<WindowsMemoryPressure>()));
    expect(runtime.processId, isNull);
  });

  test('critical pressure during active lease aborts once; release removes lease',
      () async {
    var data = healthy;
    var aborts = 0;
    final monitor = ResourceMonitor(sampler: () async => data, logger: (_) {});
    final guard = WindowsMemoryGuard(monitor, abort: () => aborts++);
    addTearDown(() { guard.release(); monitor.dispose(); });
    await guard.start();
    expect(aborts, 0);
    data = critical;
    await monitor.sample();
    await monitor.sample();
    expect(aborts, 1);
    expect(guard.check, throwsA(isA<WindowsMemoryPressure>()));
    guard.release();
    await monitor.sample();
    expect(aborts, 1);
  });

  test('unknown and non-Windows samples cannot be mistaken for Windows pressure',
      () async {
    var data = <Object?, Object?>{};
    var aborts = 0;
    final monitor = ResourceMonitor(sampler: () async => data, logger: (_) {});
    final guard = WindowsMemoryGuard(monitor, abort: () => aborts++);
    addTearDown(() { guard.release(); monitor.dispose(); });
    await guard.start();
    data = {'lowMemory': true};
    await monitor.sample();
    expect(aborts, 0);
    guard.check();
  });
}
