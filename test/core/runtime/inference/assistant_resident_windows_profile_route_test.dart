import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/assistant_resident_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCli extends LocalRuntimeProvider {
  int calls = 0;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    calls++;
    yield InferenceResponse.token(text: 'CLI', model: request.modelId);
    yield InferenceResponse.finalChunk(
      text: 'CLI', tokensGenerated: 1, model: request.modelId,
    );
  }
}

class _RecordingResident extends ResidentCompletionRuntime {
  int calls = 0;

  @override
  Stream<String> generate({
    required String executable,
    required String modelPath,
    required String sessionId,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required double topP,
    required double repeatPenalty,
    required int threads,
    int? batchSize,
    String? device,
    required CancellationToken cancellation,
    void Function(int cached, int evaluated)? onPromptUsage,
    bool rejectTokenLimit = false,
  }) async* {
    calls++;
    yield 'RESIDENT';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows Qwen2.5 3B uses exactly the canonical Self-Test CLI', () async {
    final cli = _RecordingCli();
    final resident = _RecordingResident();
    final provider = AssistantResidentLocalRuntimeProvider(
      delegate: cli,
      runtime: resident,
      executable: () => 'fake-llama-server',
      isWindowsHost: () => true,
    );
    try {
      final responses = await provider.streamInference(
        request: const InferenceRequest(
          sessionId: 'windows-qwen',
          prompt: 'Rispondi OK',
          modelId: 'qwen2_5_3b_instruct',
          modelPath: 'not-opened-by-resident.gguf',
          maxTokens: 16,
          temperature: 0,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 1);
      expect(resident.calls, 0);
      expect(responses.last.isFinal, isTrue);
      expect(responses.last.isError, isFalse);
      expect(responses.last.text, 'CLI');
    } finally {
      await provider.dispose();
    }
  });

  test('Windows measured resident model retains its existing path', () async {
    final temp = await Directory.systemTemp.createTemp('aivexus-resident-');
    final model = File('${temp.path}${Platform.pathSeparator}model.gguf');
    await model.writeAsBytes(<int>[71, 71, 85, 70], flush: true);
    final cli = _RecordingCli();
    final resident = _RecordingResident();
    final provider = AssistantResidentLocalRuntimeProvider(
      delegate: cli,
      runtime: resident,
      executable: () => 'fake-llama-server',
      isWindowsHost: () => true,
    );
    try {
      final responses = await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'windows-measured',
          prompt: 'Reply OK',
          modelId: 'phi3_5_mini',
          modelPath: model.path,
          maxTokens: 16,
          temperature: 0,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 0);
      expect(resident.calls, 1);
      expect(responses.last.isFinal, isTrue);
      expect(responses.last.text, 'RESIDENT');
    } finally {
      await provider.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('non-Windows Qwen retains the previous resident route', () async {
    final temp = await Directory.systemTemp.createTemp('aivexus-resident-');
    final model = File('${temp.path}${Platform.pathSeparator}model.gguf');
    await model.writeAsBytes(<int>[71, 71, 85, 70], flush: true);
    final cli = _RecordingCli();
    final resident = _RecordingResident();
    final provider = AssistantResidentLocalRuntimeProvider(
      delegate: cli,
      runtime: resident,
      executable: () => 'fake-llama-server',
      isWindowsHost: () => false,
    );
    try {
      final responses = await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'non-windows-qwen',
          prompt: 'Reply OK',
          modelId: 'qwen2_5_3b_instruct',
          modelPath: model.path,
          maxTokens: 16,
          temperature: 0,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 0);
      expect(resident.calls, 1);
      expect(responses.last.isFinal, isTrue);
      expect(responses.last.text, 'RESIDENT');
    } finally {
      await provider.dispose();
      await temp.delete(recursive: true);
    }
  });
}
