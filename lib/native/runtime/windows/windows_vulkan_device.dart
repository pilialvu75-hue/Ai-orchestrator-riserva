/// Conservative selection for the measured Windows NVIDIA runtime path.
/// Unknown devices or memory figures retain the CPU fallback.
abstract final class WindowsVulkanDevice {
  static String? select(String listing, {required int modelBytes}) {
    if (modelBytes <= 0) return null;
    final pattern = RegExp(
      r'^\s*(Vulkan\d+):\s*NVIDIA[^\r\n]*\((\d+) MiB, (\d+) MiB free\)\s*$',
      multiLine: true,
    );
    final requiredMiB = (modelBytes / (1024 * 1024)).ceil() + 1536;
    for (final match in pattern.allMatches(listing)) {
      final free = int.tryParse(match.group(3)!);
      if (free != null && free >= requiredMiB) return match.group(1);
    }
    return null;
  }
}
