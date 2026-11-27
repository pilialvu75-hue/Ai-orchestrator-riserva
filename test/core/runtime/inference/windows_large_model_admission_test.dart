import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_device_capacity.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_large_model_admission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  final devices = WindowsGpuDeviceCapacity.parse(
    'CUDA0: NVIDIA RTX 4060 (8192 MiB, 8192 MiB free)', cuda: true);
  WindowsLargeModelAdmission? plan(int model, List<int>? blocks, int ram) =>
      WindowsLargeModelAdmission.gpu(backend: 'cuda', devices: devices,
        modelBytes: model, blockBytes: blocks, freeRamBytes: ram);

  test('large model uses full GPU when measured blocks and reserve fit', () {
    final result = plan(5 * gib, List.filled(4, gib), 6 * gib)!;
    expect(result.backend, 'cuda');
    expect(result.device, 'CUDA0');
    expect(result.layers, 5);
  });
  test('oversized VRAM model requests only safe suffix of layers', () {
    final result = plan(9 * gib, List.filled(8, gib), 10 * gib)!;
    expect(result.layers, 5);
    expect(result.device, 'CUDA0');
  });
  test('rejects unknown layout, insufficient RAM and impossible weights', () {
    expect(plan(9 * gib, null, 10 * gib), isNull);
    expect(plan(9 * gib, List.filled(8, gib), 3 * gib), isNull);
    expect(plan(4 * gib, List.filled(8, gib), 10 * gib), isNull);
    expect(WindowsLargeModelAdmission.cpuFits(9 * gib, 10 * gib), isFalse);
    expect(WindowsLargeModelAdmission.cpuFits(5 * gib, 9 * gib), isTrue);
    expect(WindowsLargeModelAdmission.cpuFits(5 * gib, 0), isFalse);
  });
  test('integrated Vulkan memory is not a second physical memory pool', () {
    expect(WindowsLargeModelAdmission.gpu(backend: 'vulkan',
      devices: WindowsGpuDeviceCapacity.parse(
        'Vulkan0: Intel UHD (16384 MiB, 16000 MiB free)', cuda: false),
      modelBytes: 5 * gib, blockBytes: List.filled(4, gib),
      freeRamBytes: 8 * gib), isNull);
  });
  test('native layer request preserves defaults and rejects inconsistent bounds', () {
    expect(ResidentCompletionRuntime.resolveGpuLayers(null, null), 0);
    expect(ResidentCompletionRuntime.resolveGpuLayers('CUDA0', null), 99);
    expect(ResidentCompletionRuntime.resolveGpuLayers('CUDA0', 5), 5);
    expect(() => ResidentCompletionRuntime.resolveGpuLayers(null, 5), throwsArgumentError);
    expect(() => ResidentCompletionRuntime.resolveGpuLayers('CUDA0', 514), throwsArgumentError);
    expect(() => ResidentCompletionRuntime.resolveGpuLayers('CUDA0', 0), throwsArgumentError);
  });
}
