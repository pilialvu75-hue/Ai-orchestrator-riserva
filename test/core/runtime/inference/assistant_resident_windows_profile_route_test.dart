import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/core/runtime/inference/assistant_resident_local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_web_continuation_local_runtime_provider.dart';
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
  String? lastExecutable;
  String? lastDevice;
  int? lastBatchSize;
  int? lastUbatchSize;
  bool lastFlashAttention = false;
  bool failOnCuda = false;

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
    int? ubatchSize,
    bool flashAttention = false,
    String? device,
    required CancellationToken cancellation,
    void Function(int cached, int evaluated)? onPromptUsage,
    bool rejectTokenLimit = false,
  }) async* {
    calls++;
    lastExecutable = executable;
    lastDevice = device;
    lastBatchSize = batchSize;
    lastUbatchSize = ubatchSize;
    lastFlashAttention = flashAttention;
    if (failOnCuda && device?.startsWith('CUDA') == true) {
      throw StateError('simulated CUDA startup failure');
    }
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

  test('Assistant chat decorator preserves the Qwen CLI final response',
      () async {
    final cli = _RecordingCli();
    final resident = _RecordingResident();
    final assistant = AssistantWebContinuationLocalRuntimeProvider(
      delegate: AssistantResidentLocalRuntimeProvider(
        delegate: cli,
        runtime: resident,
        executable: () => 'fake-llama-server',
        isWindowsHost: () => true,
      ),
    );
    final responses = await assistant.streamInference(
      request: const InferenceRequest(
        sessionId: 'chat-route',
        prompt: 'ciao',
        modelId: 'qwen2_5_3b_instruct',
        modelPath: 'canonical-cli-only.gguf',
        maxTokens: 16,
      ),
      cancellationToken: CancellationToken(),
    ).toList();
    expect(cli.calls, 1);
    expect(resident.calls, 0);
    expect(responses.last.isFinal, isTrue);
    expect(responses.last.isError, isFalse);
    expect(responses.last.text, 'CLI');
  });


  test('ASUS Windows selects CUDA and passes bounded GPU settings', () async {
    final temp = await Directory.systemTemp.createTemp('aivexus-cuda-route-');
    final runtimeModern = Directory('${temp.path}${Platform.pathSeparator}runtime-modern');
    final runtimeCuda = Directory('${temp.path}${Platform.pathSeparator}runtime-cuda');
    final runtimeVulkan = Directory('${temp.path}${Platform.pathSeparator}runtime-vulkan');
    await runtimeModern.create();
    await runtimeCuda.create();
    await runtimeVulkan.create();
    final cpuServer = File('${runtimeModern.path}${Platform.pathSeparator}llama-server.exe');
    final cudaServer = File('${runtimeCuda.path}${Platform.pathSeparator}llama-server.exe');
    final vulkanServer = File('${runtimeVulkan.path}${Platform.pathSeparator}llama-server.exe');
    await cpuServer.writeAsString('stub');
    await cudaServer.writeAsString('stub');
    await vulkanServer.writeAsString('stub');
    final model = File('${temp.path}${Platform.pathSeparator}model.gguf');
    await model.writeAsBytes(<int>[71, 71, 85, 70], flush: true);
    final cli = _RecordingCli();
    final resident = _RecordingResident();
    final provider = AssistantResidentLocalRuntimeProvider(
      delegate: cli,
      runtime: resident,
      executable: () => cpuServer.path,
      isWindowsHost: () => true,
      isModernWindowsHost: () => true,
      gpuDeviceListing: (executable) async => p.normalize(executable) == p.normalize(cudaServer.path)
          ? 'CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 7000 MiB free)'
          : 'Vulkan0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 7000 MiB free)',
    );
    try {
      final responses = await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'asus-cuda-route',
          prompt: 'Reply OK',
          modelId: 'phi3_5_mini',
          modelPath: model.path,
          maxTokens: 16,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 0);
      expect(resident.calls, 1);
      expect(p.normalize(resident.lastExecutable!), p.normalize(cudaServer.path));
      expect(resident.lastDevice, 'CUDA0');
      expect(resident.lastBatchSize, 512);
      expect(resident.lastUbatchSize, 256);
      expect(resident.lastFlashAttention, isTrue);
      expect(responses.last.text, 'RESIDENT');
    } finally {
      await provider.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('CUDA resident startup failure falls back to Vulkan without CLI', () async {
    final temp = await Directory.systemTemp.createTemp('aivexus-cuda-fallback-');
    final runtimeModern = Directory('${temp.path}${Platform.pathSeparator}runtime-modern');
    final runtimeCuda = Directory('${temp.path}${Platform.pathSeparator}runtime-cuda');
    final runtimeVulkan = Directory('${temp.path}${Platform.pathSeparator}runtime-vulkan');
    await runtimeModern.create();
    await runtimeCuda.create();
    await runtimeVulkan.create();
    final cpuServer = File('${runtimeModern.path}${Platform.pathSeparator}llama-server.exe');
    final cudaServer = File('${runtimeCuda.path}${Platform.pathSeparator}llama-server.exe');
    final vulkanServer = File('${runtimeVulkan.path}${Platform.pathSeparator}llama-server.exe');
    await cpuServer.writeAsString('stub');
    await cudaServer.writeAsString('stub');
    await vulkanServer.writeAsString('stub');
    final model = File('${temp.path}${Platform.pathSeparator}model.gguf');
    await model.writeAsBytes(<int>[71, 71, 85, 70], flush: true);
    final cli = _RecordingCli();
    final resident = _RecordingResident()..failOnCuda = true;
    final provider = AssistantResidentLocalRuntimeProvider(
      delegate: cli,
      runtime: resident,
      executable: () => cpuServer.path,
      isWindowsHost: () => true,
      isModernWindowsHost: () => true,
      gpuDeviceListing: (executable) async => executable == cudaServer.path
          ? 'CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 7000 MiB free)'
          : 'Vulkan0: NVIDIA GeForce RTX 4060 Laptop GPU (8192 MiB, 7000 MiB free)',
    );
    try {
      final responses = await provider.streamInference(
        request: InferenceRequest(
          sessionId: 'asus-cuda-fallback',
          prompt: 'Reply OK',
          modelId: 'phi3_5_mini',
          modelPath: model.path,
          maxTokens: 16,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 0);
      expect(resident.calls, 2);
      expect(p.normalize(resident.lastExecutable!), p.normalize(vulkanServer.path));
      expect(resident.lastDevice, 'Vulkan0');
      expect(responses.last.isError, isFalse);
      expect(responses.last.text, 'RESIDENT');
    } finally {
      await provider.dispose();
      await temp.delete(recursive: true);
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

  test('Windows TinyLlama still exercises the resident server', () async {
    final temp = await Directory.systemTemp.createTemp('aivexus-tiny-resident-');
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
          sessionId: 'tinyllama-smoke',
          prompt: 'Reply OK',
          modelId: 'tinyllama',
          modelPath: model.path,
          maxTokens: 16,
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

  test('Windows imported Qwen2.5 GGUF name also uses CLI', () async {
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
          sessionId: 'windows-qwen-import',
          prompt: 'ciao',
          modelId: 'qwen2.5-3b-instruct-q4_k_m.gguf',
          modelPath: 'canonical-cli-only.gguf',
          maxTokens: 16,
        ),
        cancellationToken: CancellationToken(),
      ).toList();
      expect(cli.calls, 1);
      expect(resident.calls, 0);
      expect(responses.last.isFinal, isTrue);
      expect(responses.last.text, 'CLI');
    } finally {
      await provider.dispose();
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
