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
    });
  });
}
