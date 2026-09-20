import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown memory stays unknown, UI hidden is not critical pressure', () {
    final sample = ResourceSample({'trimLevel': 20});
    expect(sample.availableBytes, isNull);
    expect(sample.critical, isFalse);
    expect(sample.pressured, isFalse);
    expect(ResourceProfile.select(null, phi: false).context, 4096);
    expect(ResourceProfile.select(null, phi: true).context, 2048);
  });
  test('system threshold and running critical signal activate the guard', () {
    for (final values in [
      {'lowMemory': true},
      {'trimLevel': 15},
      {'availableBytes': 100, 'thresholdBytes': 100},
    ]) {
      final sample = ResourceSample(values);
      expect(sample.critical, isTrue);
      final profile = ResourceProfile.select(sample, phi: false);
      expect(profile.context, 2048);
      expect(profile.microBatch, 32);
      expect(minResourceGenerationLimit(profile.context), 1024);
    }
  });
  test(
    'sampling coalesces concurrent callers and bounds the history',
    () async {
      var calls = 0;
      final gate = Completer<Map<Object?, Object?>?>();
      final monitor = ResourceMonitor(
        sampler: () {
          calls++;
          return calls == 1
              ? gate.future
              : Future.value({'availableBytes': 123});
        },
        logger: (_) {},
      );
      final first = monitor.sample();
      final second = monitor.sample();
      expect(calls, 1);
      gate.complete({'availableBytes': 456});
      expect(await first, same(await second));
      for (var i = 0; i < 70; i++) {
        await monitor.sample();
      }
      expect(monitor.history.length, 60);
      monitor.dispose();
    },
  );
  test(
    'sample failure clears stale RAM and never becomes a zero reading',
    () async {
      var fail = false;
      final monitor = ResourceMonitor(
        sampler: () async {
          if (fail) throw StateError('sensor unavailable');
          return {'lowMemory': true};
        },
        logger: (_) {},
      );
      var cancellations = 0;
      monitor.addCriticalListener(() {
        cancellations++;
      });
      await monitor.sample();
      expect(cancellations, 1);
      fail = true;
      await monitor.sample();
      expect(monitor.latest, isNull);
      expect(cancellations, 1);
      monitor.dispose();
    },
  );
  testWidgets('panel release preserves inference sampling lease', (
    tester,
  ) async {
    var calls = 0;
    final monitor = ResourceMonitor(
      sampler: () async {
        calls++;
        return {};
      },
      logger: (_) {},
    );
    monitor.retain(); // inference
    monitor.retain(); // panel
    await tester.pump();
    monitor.release();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
    monitor.release();
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 2);
    monitor.dispose();
  });
}
