import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_generation_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native terminal statistics belong to the completed request', () {
    final monitor = WindowsGenerationMetrics();
    addTearDown(monitor.dispose);
    final id = monitor.begin()!;
    expect(monitor.phase, 'preparing');
    expect(monitor.terminal, isNull);
    monitor.selectRoute(id, 'cuda');
    monitor.firstText(id);
    expect(monitor.phase, 'streaming');
    expect(monitor.firstTextMs, isNotNull);
    const stats = ResidentGenerationMetrics(generatedTokens: 12, tokensPerSecond: 24);
    monitor.finish(id, success: true, stats: stats);
    expect(monitor.phase, 'completed');
    expect(monitor.route, 'cuda');
    expect(monitor.terminal, same(stats));
    monitor.finish(id, success: false);
    expect(monitor.terminal, same(stats));
    final elapsed = monitor.elapsedMs;
    expect(elapsed, isNotNull);
    final next = monitor.begin()!;
    expect(next, isNot(id));
    expect(monitor.terminal, isNull);
    expect(monitor.firstTextMs, isNull);
    expect(monitor.route, isNull);
  });

  test('older attempt cannot overwrite a newer fallback', () {
    final monitor = WindowsGenerationMetrics();
    addTearDown(monitor.dispose);
    final old = monitor.begin()!;
    monitor.selectRoute(old, 'cuda');
    expect(monitor.begin(), isNull, reason: 'A competing request must not overwrite the active attempt.');
    expect(monitor.route, 'cuda');
    monitor.finish(old, success: false);
    final current = monitor.begin()!;
    monitor.selectRoute(current, 'resident_cpu');
    monitor.firstText(old);
    monitor.selectRoute(old, 'vulkan');
    monitor.finish(old, success: true,
        stats: const ResidentGenerationMetrics(generatedTokens: 99));
    expect(monitor.phase, 'preparing');
    expect(monitor.route, 'resident_cpu');
    expect(monitor.terminal, isNull);
    monitor.firstText(current);
    monitor.finish(current, success: false);
    expect(monitor.phase, 'interrupted');
    expect(monitor.terminal, isNull);
  });

  test('CLI completion never turns estimated tokens into native measurements', () {
    final monitor = WindowsGenerationMetrics();
    addTearDown(monitor.dispose);
    final id = monitor.begin()!;
    monitor.selectRoute(id, 'process_cli');
    monitor.firstText(id);
    monitor.finish(id, success: true);
    expect(monitor.phase, 'completed');
    expect(monitor.terminal, isNull);
  });
}
