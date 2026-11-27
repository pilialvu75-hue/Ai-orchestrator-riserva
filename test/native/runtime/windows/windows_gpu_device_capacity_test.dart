import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_device_capacity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads device capacities without treating integrated GPU as dedicated', () {
    final devices = WindowsGpuDeviceCapacity.parse(
      'Vulkan0: Intel(R) UHD Graphics (8000 MiB, 7000 MiB free)\n'
      'Vulkan1: NVIDIA GeForce RTX 4060 (8192 MiB, 6000 MiB free)\n'
      'Vulkan2: AMD Radeon RX 7600 (8192 MiB, 5000 MiB free)\n'
      'Vulkan3: Intel(R) Arc(TM) A770 (16384 MiB, 10000 MiB free)',
      cuda: false,
    );
    expect(devices.length, 4);
    expect(devices.first.isDiscreteCandidate, isFalse);
    expect(devices.skip(1).every((device) => device.isDiscreteCandidate), isTrue);
    expect(devices[1].freeBytes, 6000 * 1048576);
  });
  test('CUDA accepts NVIDIA only and rejects impossible or duplicate readings', () {
    final devices = WindowsGpuDeviceCapacity.parse(
      'INFO CUDA0: NVIDIA GPU (8192 MiB, 5000 MiB free)\n'
      'CUDA1: NVIDIA GPU (8192 MiB, 9000 MiB free)\n'
      'CUDA2: Intel GPU (8192 MiB, 5000 MiB free)\n'
      'CUDA3: NVIDIA GPU (8192 MiB, 6000 MiB free)\n'
      'CUDA3: NVIDIA GPU (8192 MiB, 7000 MiB free)\n'
      'CUDA4: NVIDIA GPU (8192 MiB, 0 MiB free)',
      cuda: true,
    );
    expect(devices.map((d) => d.device), ['CUDA0', 'CUDA4']);
    expect(devices.last.freeBytes, 0);
  });
}
