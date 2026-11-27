import 'package:ai_orchestrator/core/runtime/inference/windows_gpu_metrics.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_wddm_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WDDM utilization sums processes on one engine then takes the maximum', () {
    final samples = WindowsWddmMemorySample.parse(
      'luid_0x0_0x123_phys_0|1024|2048\n'
      'E|pid_1_luid_0x0_0x123_phys_0_eng_0_engtype_3D|30\n'
      'E|pid_2_luid_0x0_0x123_phys_0_eng_0_engtype_3D|40\n'
      'E|pid_1_luid_0x0_0x123_phys_0_eng_1_engtype_compute|60\n'
      'E|pid_1_luid_0x0_0x456_phys_0_eng_0_engtype_3D|0\n',
    );
    expect(samples.length, 2);
    expect(samples.first.busiestEnginePercent, 70);
    expect(samples.first.dedicatedBytes, 1024);
    expect(samples.last.busiestEnginePercent, 0);
    expect(samples.last.dedicatedBytes, isNull);
  });

  test('missing or inconsistent WDDM utilization is unknown, not zero', () {
    const memory = 'luid_0x0_0x123_phys_0|1024|2048\n';
    const prefix = 'E|pid_1_luid_0x0_0x123_phys_0_eng_0_engtype_3D|';
    for (final suffix in [
      '',
      '${prefix}101\n',
      '${prefix}bad\n',
      '${prefix}40\n${prefix}40\n',
      '${prefix}80\nE|pid_2_luid_0x0_0x123_phys_0_eng_0_engtype_3D|30\n',
    ]) {
      final reading = WindowsWddmMemorySample.parse(memory + suffix).single;
      expect(reading.busiestEnginePercent, isNull);
      expect(reading.sharedBytes, 2048);
    }
  });

  test('WDDM memory keeps adapters and dedicated/shared bytes separate', () {
    final samples = WindowsWddmMemorySample.parse(
      'luid_0x00000000_0x00001234_phys_0|0|1073741824\r\n'
      'luid_0x00000000_0x00005678_phys_0|2147483648|0\n',
    );
    expect(samples.length, 2);
    expect(samples.first.dedicatedBytes, 0);
    expect(samples.first.sharedBytes, 1 << 30);
    expect(samples.last.dedicatedBytes, 2 << 30);
    expect(samples.last.sharedBytes, 0);
  });

  test('missing values are unknown, duplicates and invalid identities ignored', () {
    final samples = WindowsWddmMemorySample.parse(
      'luid_0x0_0x123_phys_0||1024\n'
      'luid_0x0_0x123_phys_0|999|999\n'
      'luid_0x0_0x456_phys_0|-1|\n'
      '_Total|100|100\n'
      'invalid|0|0\n',
    );
    expect(samples.length, 1);
    expect(samples.single.dedicatedBytes, isNull);
    expect(samples.single.sharedBytes, 1024);
    expect(WindowsWddmMemorySample.parse(''), isEmpty);
  });

  testWidgets('NVIDIA failure does not hide WDDM and release clears memory',
      (tester) async {
    final monitor = WindowsGpuMetrics(
      sampler: () async => throw StateError('NVIDIA unavailable'),
      wddmSampler: () async => [
        const WindowsWddmMemorySample('luid_0x0_0x123_phys_0', 0, 1024),
      ],
      logger: (_) {},
    );
    addTearDown(monitor.dispose);
    monitor.retain();
    await tester.pump();
    expect(monitor.latest, isEmpty);
    expect(monitor.wddmLatest.single.sharedBytes, 1024);
    monitor.release();
    expect(monitor.wddmLatest, isEmpty);
  });
}
