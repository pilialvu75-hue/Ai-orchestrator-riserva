import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/windows_gpu_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device-wide measurements preserve zero and distinct devices', () {
    final readings = WindowsGpuSample.parse(
      '0, NVIDIA GeForce RTX 4060 Laptop GPU, 0, 512, 8192\r\n'
      '1, NVIDIA RTX A4000, 80, 2048, 16384\n',
    );
    expect(readings.length, 2);
    expect(readings.first.utilizationPercent, 0);
    expect(readings.first.usedMiB, 512);
    expect(readings.first.totalMiB, 8192);
    expect(readings.last.index, 1);
    expect(readings.last.utilizationPercent, 80);
  });

  test('unsupported or invalid values stay unknown', () {
    final readings = WindowsGpuSample.parse(
      '0, NVIDIA test, [N/A], [Not Supported], 8192\n'
      '1, NVIDIA test, 101, 8193, 8192\n'
      '2, NVIDIA test, -5, -1, 0\n'
      '1, duplicate, 50, 20, 200\n'
      'invalid output\n',
    );
    expect(readings.length, 3);
    for (final sample in readings) {
      expect(sample.utilizationPercent, isNull);
      expect(sample.usedMiB, isNull);
    }
    expect(readings.first.totalMiB, 8192);
    expect(readings.last.totalMiB, isNull);
    expect(WindowsGpuSample.parse('No devices were found'), isEmpty);
  });

  testWidgets('sampling is shared, periodic and limited to visible panels',
      (tester) async {
    var calls = 0;
    var fail = false;
    final monitor = WindowsGpuMetrics(
      sampler: () async {
        calls++;
        if (fail) throw StateError('driver unavailable');
        return [const WindowsGpuSample(0, 'GPU', 10, 100, 1000)];
      },
      logger: (_) {},
    );
    addTearDown(monitor.dispose);
    await monitor.sample();
    expect(calls, 0);
    monitor.retain();
    monitor.retain();
    await tester.pump();
    expect(calls, 1);
    expect(monitor.latest.single.usedMiB, 100);
    monitor.release();
    fail = true;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 2);
    expect(monitor.latest, isEmpty);
    monitor.release();
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
  });

  testWidgets('late result is discarded after closing and reopening',
      (tester) async {
    final old = Completer<List<WindowsGpuSample>>();
    var calls = 0;
    final monitor = WindowsGpuMetrics(
      sampler: () {
        calls++;
        return calls == 1
            ? old.future
            : Future.value([const WindowsGpuSample(0, 'new GPU', 20, 200, 1000)]);
      },
      logger: (_) {},
    );
    addTearDown(monitor.dispose);
    monitor.retain();
    monitor.release();
    monitor.retain();
    old.complete([const WindowsGpuSample(0, 'old GPU', 90, 900, 1000)]);
    await tester.pump();
    expect(monitor.latest, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    expect(monitor.latest.single.name, 'new GPU');
    monitor.release();
    expect(monitor.latest, isEmpty);
  });
}
