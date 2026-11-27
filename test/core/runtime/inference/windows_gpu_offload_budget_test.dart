import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_offload_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  WindowsGpuOffloadBudget? plan({
    int modelBytes = 9 * gib,
    List<int> blocks = const [gib, gib, gib, gib, gib, gib, gib, gib],
    int vram = 8 * gib,
    int ram = 10 * gib,
    int reserve = 2 * gib,
  }) => WindowsGpuOffloadBudget.partial(
    modelBytes: modelBytes, blockBytes: blocks,
    freeVramBytes: vram, freeRamBytes: ram,
    gpuReserveBytes: reserve, hostReserveBytes: 2 * gib,
  );

  test('selects largest suffix fitting both memory pools', () {
    final result = plan()!;
    expect(result.layers, 5);
    expect(result.estimatedGpuBytes, lessThanOrEqualTo(8 * gib));
    expect(result.estimatedHostBytes, lessThanOrEqualTo(10 * gib));
  });

  test('uses measured uneven blocks in model order', () {
    final result = plan(modelBytes: 8 * gib,
        blocks: [gib, 3 * gib, gib, 2 * gib], vram: 6 * gib)!;
    expect(result.layers, 2);
    expect(result.estimatedGpuBytes, 2 * gib + 3 * gib + 3 * gib ~/ 8);
  });

  test('does not attempt unsafe or unmeasurable partial loads', () {
    expect(plan(ram: 3 * gib), isNull);
    expect(plan(vram: 2 * gib), isNull);
    expect(plan(ram: 0), isNull);
    expect(plan(reserve: 0), isNull);
    expect(plan(modelBytes: 2 * gib), isNull);
    expect(plan(blocks: [gib, 0]), isNull);
    expect(plan(blocks: []), isNull);
    expect(plan(modelBytes: 20 * gib, ram: 10 * gib), isNull);
  });

  test('partial mode never requests all blocks or output layer', () {
    expect(plan(vram: 32 * gib, ram: 10 * gib)!.layers, 7);
  });
}
