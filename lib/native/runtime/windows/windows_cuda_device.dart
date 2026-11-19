/// NVIDIA CUDA device selection for the bundled Windows llama.cpp server.
/// Unknown formats or tight VRAM headroom deliberately fall through to Vulkan/CPU.
abstract final class WindowsCudaDevice {
  static const int _requiredHeadroomMiB = 2048;

  static String? select(String listing, {required int modelBytes}) {
    if (modelBytes <= 0) return null;
    final pattern = RegExp(
      r'^\s*(CUDA\d+):\s*NVIDIA[^\r\n]*\((\d+) MiB, (\d+) MiB free\)\s*$',
      multiLine: true,
    );
    final requiredMiB = (modelBytes / (1024 * 1024)).ceil() + _requiredHeadroomMiB;
    for (final match in pattern.allMatches(listing)) {
      final free = int.tryParse(match.group(3)!);
      if (free != null && free >= requiredMiB) return match.group(1);
    }
    return null;
  }
}
