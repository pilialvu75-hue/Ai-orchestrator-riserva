import 'package:ai_orchestrator/presentation/chat/controllers/execution_hardware_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExecutionHardwareController', () {
    test('extracts the llama.cpp backend from runtime logs', () {
      expect(
        ExecutionHardwareController.backendFromRuntimeLog(
          '[GPU_ASSIGN] session=1 n_gpu_layers=99 backend=vulkan',
        ),
        'vulkan',
      );

      expect(
        ExecutionHardwareController.backendFromRuntimeLog(
          '[GPU_DETECT] vulkan=disabled gpu_layers=0 backend=cpu',
        ),
        'cpu',
      );

      expect(
        ExecutionHardwareController.backendFromRuntimeLog(
          '[GPU_DETECT] vulkan=disabled gpu_layers=0 backend=fallback-llama',
        ),
        'cpu',
      );

      expect(
        ExecutionHardwareController.backendFromRuntimeLog(
          '[GPU_DETECT] vulkan=enabled requested_gpu_layers=99',
        ),
        'vulkan',
      );

      expect(
        ExecutionHardwareController.backendFromRuntimeLog(
          '[GPU_DETECT] vulkan=disabled requested_gpu_layers=99 effective_gpu_layers=0',
        ),
        'cpu',
      );
    });

    test('normalizes backend labels consistently', () {
      expect(ExecutionHardwareController.normalizeBackendName(null), 'unknown');
      expect(ExecutionHardwareController.normalizeBackendName(''), 'unknown');
      expect(ExecutionHardwareController.normalizeBackendName('vulkan'), 'vulkan');
      expect(ExecutionHardwareController.normalizeBackendName('fallback-llama'), 'cpu');
    });
  });
}
