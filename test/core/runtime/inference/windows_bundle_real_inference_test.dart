import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_llama_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _BundledProvider extends LocalRuntimeProvider {
  _BundledProvider(this.helper);
  final String helper;
  @override
  Future<Process> startRuntimeProcess(String executable, List<String> arguments) {
    final resolved = WindowsLlamaRuntime.resolveExecutable(
      appExecutable: File(helper).parent.path + r'\ai_orchestrator.exe',
      environment: const {'LLAMA_CPP_EXECUTABLE': r'C:\missing\old-workaround.exe'},
    );
    return Process.start(resolved, arguments, workingDirectory: Directory.systemTemp.path);
  }
}

void main() {
  final helper = Platform.environment['AI_ORCHESTRATOR_WINDOWS_SMOKE_HELPER'];
  final model = Platform.environment['AI_ORCHESTRATOR_WINDOWS_SMOKE_MODEL'];
  test('bundled Windows provider generates real GGUF text repeatedly', () async {
    final provider = _BundledProvider(helper!);
    for (var turn = 0; turn < 2; turn++) {
      final responses = await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'bundle-smoke-$turn', prompt: 'Once upon a time',
          modelId: 'tinyllama', modelPath: model, maxTokens: 8, temperature: 0,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(responses.last.isFinal, isTrue);
      expect(responses.last.isError, isFalse, reason: responses.last.errorMessage);
      expect(responses.last.text.trim(), isNotEmpty);
      expect(responses.last.text, isNot(contains('[end of text]')));
      expect(provider.isRuntimeVerified(modelPath: model), isTrue);
    }
  }, skip: !Platform.isWindows || helper == null || model == null,
     timeout: const Timeout(Duration(minutes: 3)));
}
