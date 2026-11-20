import 'package:ai_orchestrator/native/runtime/windows/windows_cuda_device.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects NVIDIA CUDA only with model plus conservative VRAM headroom', () {
    const listing = 'CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 7000 MiB free)';
    expect(WindowsCudaDevice.select(listing, modelBytes: 4 * 1024 * 1024),
        'CUDA0');
    expect(WindowsCudaDevice.select(listing, modelBytes: 6 * 1024 * 1024 * 1024),
        isNull);
  });

  test('accepts timestamped llama.cpp log prefix without weakening VRAM gate', () {
    const listing = '''
2026-11-20 15:30:00.123 INFO CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 6400 MiB free)
2026-11-20 15:30:00.124 INFO CUDA1: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 2100 MiB free)
''';
    expect(WindowsCudaDevice.select(listing, modelBytes: 2840000000), 'CUDA0');
    expect(WindowsCudaDevice.select(listing, modelBytes: 6400 * 1024 * 1024), isNull);
  });

  test('unknown devices and unknown memory output fall back safely', () {
    expect(WindowsCudaDevice.select(
        'CUDA0: Intel integrated graphics (8192 MiB, 7000 MiB free)',
        modelBytes: 1024), isNull);
    expect(WindowsCudaDevice.select(
        'CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU',
        modelBytes: 1024), isNull);
  });

  test('selects a later NVIDIA device when the first lacks headroom', () {
    const listing = '''
CUDA0: NVIDIA GeForce RTX 4060 (8192 MiB, 1000 MiB free)
CUDA1: NVIDIA GeForce RTX 4080 (16384 MiB, 12000 MiB free)
''';
    expect(WindowsCudaDevice.select(listing, modelBytes: 1024), 'CUDA1');
  });
}
