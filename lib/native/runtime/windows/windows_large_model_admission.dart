import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_device_capacity.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_offload_budget.dart';

class WindowsLargeModelAdmission {
  const WindowsLargeModelAdmission(this.backend, this.device, this.layers);
  final String backend;
  final String? device;
  final int layers;

  // First rollout applies the stricter admission path to files above 4 GiB.
  // This is a protection trigger, not a model eligibility limit.
  static const protectedFileBytes = 4 * 1024 * 1024 * 1024;
  static const reserveBytes = 2 * 1024 * 1024 * 1024;

  static int _extra(int bytes) => bytes ~/ 8 + (bytes % 8 == 0 ? 0 : 1);

  static bool cpuFits(int modelBytes, int freeRamBytes) {
    final budget = freeRamBytes - reserveBytes;
    return modelBytes > 0 && modelBytes <= budget &&
        _extra(modelBytes) <= budget - modelBytes;
  }

  /// NVIDIA-only for the first real partial-offload trial: do not count
  /// integrated or unverified shared Vulkan capacity as independent VRAM.
  /// A plan is an estimate; the active RAM guard and engine validation
  /// remain required. Do not retry on CPU after a failed guarded load.
  static WindowsLargeModelAdmission? gpu({
    required String backend,
    required List<WindowsGpuDeviceCapacity> devices,
    required int modelBytes,
    required List<int>? blockBytes,
    required int freeRamBytes,
  }) {
    if ((backend != 'cuda' && backend != 'vulkan') ||
        freeRamBytes <= reserveBytes || modelBytes <= 0 ||
        blockBytes == null || blockBytes.length < 2 || blockBytes.length > 512) {
      return null;
    }
    var blockTotal = 0;
    for (final bytes in blockBytes) {
      if (bytes <= 0 || bytes > modelBytes - blockTotal) return null;
      blockTotal += bytes;
    }
    // Consider non-block tensors on the host even when offload is complete.
    final hostBytes = modelBytes - blockTotal;
    final hostBudget = freeRamBytes - reserveBytes;
    final candidates = devices.where((d) => d.isNvidia &&
        d.device.startsWith(backend == 'cuda' ? 'CUDA' : 'Vulkan')).toList()
      ..sort((a, b) => b.freeBytes.compareTo(a.freeBytes));
    if (hostBytes <= hostBudget && _extra(hostBytes) <= hostBudget - hostBytes) {
      for (final d in candidates) {
        final gpuBudget = d.freeBytes - reserveBytes;
        if (modelBytes <= gpuBudget && _extra(modelBytes) <= gpuBudget - modelBytes) {
          return WindowsLargeModelAdmission(backend, d.device, blockBytes.length + 1);
        }
      }
    }
    WindowsLargeModelAdmission? best;
    for (final d in candidates) {
      final plan = WindowsGpuOffloadBudget.partial(
        modelBytes: modelBytes, blockBytes: blockBytes,
        freeVramBytes: d.freeBytes, freeRamBytes: freeRamBytes,
        gpuReserveBytes: reserveBytes, hostReserveBytes: reserveBytes,
      );
      if (plan != null && (best == null || plan.layers > best.layers)) {
        best = WindowsLargeModelAdmission(backend, d.device, plan.layers);
      }
    }
    return best;
  }
}
