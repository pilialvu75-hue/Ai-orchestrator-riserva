/// A planning estimate, not proof of driver allocation or model compatibility.
/// Caller must supply fresh memory measurements and actual GGUF layer sizes
/// (in model order), never estimates from a model name or parameter count.
class WindowsGpuOffloadBudget {
  const WindowsGpuOffloadBudget._(this.layers, this.estimatedGpuBytes,
      this.estimatedHostBytes);

  final int layers;
  final int estimatedGpuBytes, estimatedHostBytes;

  static const int mib = 1024 * 1024;

  /// llama.cpp offloads the final transformer blocks first. Account for all
  /// remaining file bytes on the host, plus conservative independent reserves.
  /// Partial mode deliberately excludes output/embedding offload.
  /// Unknown/invalid budgets or no safe partial fit return null.
  static WindowsGpuOffloadBudget? partial({
    required int modelBytes,
    required List<int> blockBytes,
    required int freeVramBytes,
    required int freeRamBytes,
    required int gpuReserveBytes,
    required int hostReserveBytes,
  }) {
    if (modelBytes <= 0 ||
        blockBytes.length < 2 || blockBytes.length > 512 ||
        freeVramBytes <= 0 || freeRamBytes <= 0 ||
        gpuReserveBytes < 2048 * mib || hostReserveBytes < 2048 * mib ||
        blockBytes.any((bytes) => bytes <= 0 || bytes > modelBytes)) {
      return null;
    }
    var blockTotal = 0;
    for (final bytes in blockBytes) {
      // Reject malformed totals without overflowing a signed native int.
      if (bytes > modelBytes - blockTotal) return null;
      blockTotal += bytes;
    }
    final gpuBudget = freeVramBytes - gpuReserveBytes;
    final hostBudget = freeRamBytes - hostReserveBytes;
    if (gpuBudget <= 0 || hostBudget <= 0) return null;
    var offloaded = 0;
    // Leave at least one transformer block on CPU in partial mode.
    for (var layers = 1; layers < blockBytes.length; layers++) {
      final next = blockBytes[blockBytes.length - layers];
      if (next > gpuBudget - offloaded) break;
      offloaded += next;
      // 12.5% weight-allocation allowance on each side, rounded up.
      final gpuExtra = offloaded ~/ 8 + (offloaded % 8 == 0 ? 0 : 1);
      final hostWeights = modelBytes - offloaded;
      final hostExtra = hostWeights ~/ 8 + (hostWeights % 8 == 0 ? 0 : 1);
      if (gpuExtra > gpuBudget - offloaded) break;
      // Evaluate all fitting suffixes; retain the largest that leaves RAM.
      if (hostWeights <= hostBudget && hostExtra <= hostBudget - hostWeights) {
        // Continue looking for a larger feasible suffix below.
        // Return only after scanning, so the caller gets maximum safe layers.
      }
    }
    // Scan downward from the maximum GPU-fitting suffix. Host need increases
    // as layers are removed, so a failed host check cannot be repaired by
    // moving additional weights to CPU.
    var selected = 0;
    offloaded = 0;
    for (var i = blockBytes.length - 1; i > 0; i--) {
      final next = blockBytes[i];
      if (next > gpuBudget - offloaded) break;
      final candidate = offloaded + next;
      final extra = candidate ~/ 8 + (candidate % 8 == 0 ? 0 : 1);
      if (extra > gpuBudget - candidate) break;
      offloaded = candidate;
      selected++;
    }
    if (selected == 0) return null;
    final hostWeights = modelBytes - offloaded;
    final hostExtra = hostWeights ~/ 8 + (hostWeights % 8 == 0 ? 0 : 1);
    if (hostWeights > hostBudget || hostExtra > hostBudget - hostWeights) {
      return null;
    }
    final gpuExtra = offloaded ~/ 8 + (offloaded % 8 == 0 ? 0 : 1);
    return WindowsGpuOffloadBudget._(selected,
        offloaded + gpuExtra + gpuReserveBytes,
        hostWeights + hostExtra + hostReserveBytes);
  }
}
