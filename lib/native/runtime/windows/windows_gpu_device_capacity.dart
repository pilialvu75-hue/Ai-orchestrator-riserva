/// A runtime-reported GPU capacity, not a guarantee of dedicated VRAM.
/// Vulkan integrated devices may report shared system memory. The planner
/// must not add such capacity to physical RAM as an independent pool.
class WindowsGpuDeviceCapacity {
  const WindowsGpuDeviceCapacity._(
      this.device, this.name, this.totalMiB, this.freeMiB);

  final String device, name;
  final int totalMiB, freeMiB;
  static const int _mib = 1024 * 1024;
  int get totalBytes => totalMiB * _mib;
  int get freeBytes => freeMiB * _mib;

  bool get isNvidia => name.startsWith('NVIDIA');
  // Narrow candidates only. Runtime listing alone is not proof of separate
  // physical memory; the caller must verify it before partial offload.
  bool get isDiscreteCandidate => isNvidia ||
      RegExp(r'^AMD Radeon RX\s+\d', caseSensitive: false).hasMatch(name) ||
      RegExp(r'^Intel(?:\(R\))?\s+Arc(?:\(TM\))?\s+[AB]\d{3}', caseSensitive: false)
          .hasMatch(name);

  static List<WindowsGpuDeviceCapacity> parse(String listing,
      {required bool cuda}) {
    final prefix = cuda ? 'CUDA' : 'Vulkan';
    final pattern = RegExp(
      '^[^\\r\\n]*?\\b($prefix\\d+):\\s*([^\\r\\n]+?)\\s*'
      r'\((\d+) MiB,\s*(\d+) MiB free\)\s*$',
      multiLine: true,
    );
    final candidates = <WindowsGpuDeviceCapacity>[];
    final seen = <String>{};
    final duplicates = <String>{};
    for (final match in pattern.allMatches(listing)) {
      final id = match.group(1)!;
      if (!seen.add(id)) {
        duplicates.add(id);
        continue;
      }
      final name = match.group(2)!.trim();
      final total = int.tryParse(match.group(3)!);
      final free = int.tryParse(match.group(4)!);
      // Bounds also prevent overflow when converting MiB to bytes.
      if (total == null || free == null || total <= 0 ||
          total > 1048576 || free < 0 || free > total) continue;
      final reading = WindowsGpuDeviceCapacity._(id, name, total, free);
      if (cuda && !reading.isNvidia) continue;
      candidates.add(reading);
    }
    return List.unmodifiable(candidates.where(
        (candidate) => !duplicates.contains(candidate.device)));
  }
}
