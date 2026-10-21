import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_vulkan_device.dart';

void main() {
  test('selects discrete NVIDIA with headroom instead of first Intel device', () {
    const listing = 'Available devices:\n'
        '  Vulkan0: Intel(R) UHD Graphics (8003 MiB, 7347 MiB free)\n'
        '  Vulkan1: NVIDIA GeForce RTX 4060 Laptop GPU (7957 MiB, 7189 MiB free)\n';
    expect(WindowsVulkanDevice.select(listing, modelBytes: 2837072864), 'Vulkan1');
    expect(WindowsVulkanDevice.select(listing, modelBytes: 7 * 1024 * 1024 * 1024), isNull);
  });
  test('unknown memory, unsupported or missing devices retain CPU', () {
    for (final listing in ['', 'Vulkan0: NVIDIA unknown',
      'Vulkan0: Intel UHD (8000 MiB, 7000 MiB free)',
      'Vulkan1: NVIDIA GPU (8000 MiB, 100 MiB free)']) {
      expect(WindowsVulkanDevice.select(listing, modelBytes: 2837072864), isNull);
    }
    expect(WindowsVulkanDevice.select('Vulkan0: NVIDIA GPU (8000 MiB, 7000 MiB free)', modelBytes: 0), isNull);
  });
}
