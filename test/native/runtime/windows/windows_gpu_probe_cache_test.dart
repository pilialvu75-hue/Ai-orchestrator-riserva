import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_probe_cache.dart';

void main() {
  test('cold admission explicitly refreshes cached free VRAM and failures', () async {
    var calls = 0;
    final cache = WindowsGpuProbeCache();
    Future<String?> probe() async {
      calls++;
      if (calls == 1) return '7000 MiB';
      if (calls == 2) return null;
      return '3000 MiB';
    }
    bool usable(String value) => value.isNotEmpty;
    expect(await cache.get(probe, usable: usable), '7000 MiB');
    expect(await cache.get(probe, usable: usable), '7000 MiB');
    expect(await cache.get(probe, usable: usable, fresh: true), isNull);
    expect(await cache.get(probe, usable: usable, fresh: true), '3000 MiB');
    expect(calls, 3);
  });

  test('transient failure is retried only after cooldown', () async {
    var time = Duration.zero;
    var calls = 0;
    final cache = WindowsGpuProbeCache(now: () => time);
    Future<String?> probe() async => ++calls == 1 ? null : 'NVIDIA ready';
    bool usable(String value) => value == 'NVIDIA ready';
    expect(await cache.get(probe, usable: usable), isNull);
    time = const Duration(seconds: 29);
    expect(await cache.get(probe, usable: usable), isNull);
    expect(calls, 1);
    time = const Duration(seconds: 30);
    expect(await cache.get(probe, usable: usable), 'NVIDIA ready');
    time = const Duration(hours: 1);
    expect(await cache.get(probe, usable: usable), 'NVIDIA ready');
    expect(calls, 2);
  });
  test('insufficient headroom listing can recover on a later request', () async {
    var time = Duration.zero;
    var calls = 0;
    final cache = WindowsGpuProbeCache(now: () => time);
    Future<String?> probe() async => ++calls == 1 ? 'low headroom' : 'ready';
    bool usable(String value) => value == 'ready';
    expect(await cache.get(probe, usable: usable), 'low headroom');
    time = const Duration(seconds: 30);
    expect(await cache.get(probe, usable: usable), 'ready');
    expect(calls, 2);
  });
  test('concurrent callers share a probe and thrown probe can recover', () async {
    var time = Duration.zero;
    final cache = WindowsGpuProbeCache(now: () => time);
    final pending = Completer<String?>();
    var calls = 0;
    Future<String?> probe() { calls++; return pending.future; }
    final first = cache.get(probe, usable: (_) => true);
    final second = cache.get(probe, usable: (_) => true);
    pending.completeError(StateError('temporary'));
    expect(await first, isNull);
    expect(await second, isNull);
    expect(calls, 1);
    time = const Duration(seconds: 30);
    expect(await cache.get(() async => 'ready', usable: (_) => true), 'ready');
  });
}
