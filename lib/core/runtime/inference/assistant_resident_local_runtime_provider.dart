import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/completion_output.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_reasoning_output.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_windows_gpu_policy.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/sampling_metadata.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_llama_runtime.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_vulkan_device.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_probe_cache.dart';

/// Assistant-only warm desktop runtime. Workshop and diagnostics retain their
/// canonical provider. Unsupported platforms and startup failures use the CLI.
final class AssistantResidentLocalRuntimeProvider extends LocalRuntimeProvider {
  AssistantResidentLocalRuntimeProvider({required LocalRuntimeProvider delegate,
      ResidentCompletionRuntime? runtime, String? Function()? executable})
      : _delegate = delegate, _runtime = runtime ?? ResidentCompletionRuntime(),
        _executable = executable ?? _bundledServer;

  final LocalRuntimeProvider _delegate;
  final ResidentCompletionRuntime _runtime;
  final String? Function() _executable;
  AppLifecycleListener? _lifecycle;
  bool _unavailable = false;
  bool _gpuUnavailable = false;
  final _gpuDevices = WindowsGpuProbeCache();
  Future<void>? _preparation;

  /// Prepare only the measured Windows GPU route while the app opens.
  /// This does not verify inference or populate the conversation cache.
  Future<void> prepareSelectedModel(AiModel model) {
    return _preparation ??= _prepareSelectedModel(model);
  }

  Future<void> _prepareSelectedModel(AiModel model) async {
    if (!Platform.isWindows || _gpuUnavailable ||
        !AssistantWindowsGpuPolicy.supports(model.effectiveRuntimeModelId)) return;
    final cpuExecutable = _executable();
    final modelPath = model.localPath;
    if (cpuExecutable == null || modelPath == null || !File(modelPath).existsSync()) return;
    final candidate = p.join(p.dirname(cpuExecutable), '..', 'runtime-vulkan', 'llama-server.exe');
    if (!File(candidate).existsSync()) return;
    final watch = Stopwatch()..start();
    try {
      final listing = await _gpuDevices.get(() => _listGpuDevices(candidate),
          usable: (value) => WindowsVulkanDevice.select(value, modelBytes: File(modelPath).lengthSync()) != null);
      final device = WindowsVulkanDevice.select(listing ?? '', modelBytes: await File(modelPath).length());
      if (device == null) {
        RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] stage=prepare reason=no_eligible_device_or_headroom');
        return;
      }
      await _runtime.prepare(executable: candidate, modelPath: modelPath,
          sessionId: 'default', threads: (Platform.numberOfProcessors ~/ 2).clamp(1, 8), device: device);
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_PREPARE] status=ready elapsed_ms=${watch.elapsedMilliseconds}');
    } catch (_) {
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_PREPARE] status=failed action=normal_request_startup');
    }
  }

  Future<String?> _listGpuDevices(String executable) async {
    Process? probe;
    try {
      probe = await Process.start(executable, ['--list-devices']);
      final stdout = probe.stdout.transform(utf8.decoder).join();
      final stderr = probe.stderr.drain<void>();
      final code = await probe.exitCode.timeout(const Duration(seconds: 15));
      await stderr;
      final listing = await stdout;
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU_PROBE] exit_code=$code output_chars=${listing.length}');
      return code == 0 ? listing : null;
    } catch (error) {
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU_PROBE] error_type=${error.runtimeType}');
      return null;
    } finally {
      probe?.kill();
    }
  }

  static String? _bundledServer() {
    final appDir = p.dirname(Platform.resolvedExecutable);
    if (Platform.isWindows) {
      if (!WindowsLlamaRuntime.isModernWindows(Platform.operatingSystemVersion)) return null;
      final file = p.join(appDir, 'runtime-modern', 'llama-server.exe');
      return File(file).existsSync() ? file : null;
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final file = p.join(appDir, 'llama-server');
      return File(file).existsSync() ? file : null;
    }
    return null;
  }

  @override
  bool supportsModel(AiModel model) => _delegate.supportsModel(model);
  @override
  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) =>
      _delegate.validateRuntime(selectedModel: selectedModel);
  @override
  bool isRuntimeVerified({String? modelPath}) => _delegate.isRuntimeVerified(modelPath: modelPath);
  @override
  void clearRuntimeVerification() => _delegate.clearRuntimeVerification();
  @override
  void markRuntimeVerified(String modelPath) => _delegate.markRuntimeVerified(modelPath);
  @override
  int get activeLifecycleTransitionId => _delegate.activeLifecycleTransitionId;
  @override
  String get lifecycleRuntimeStateName => _delegate.lifecycleRuntimeStateName;

  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    await _runtime.close();
  }

  @override
  TokenStream streamInference({required InferenceRequest request,
      required CancellationToken cancellationToken}) async* {
    final executable = _unavailable ? null : _executable();
    if (executable == null) {
      yield* _delegate.streamInference(request: request, cancellationToken: cancellationToken);
      return;
    }
    final preparing = _preparation;
    if (preparing != null) {
      final cancelled = Completer<void>();
      cancellationToken.onCancel(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await Future.any<void>([preparing, cancelled.future]);
    }
    if (cancellationToken.isCancelled) {
      yield InferenceResponse.error('Inference cancelled.', state: InferenceTerminalState.cancelled);
      return;
    }
    _lifecycle ??= AppLifecycleListener(
      onDetach: () => unawaited(_runtime.close()),
      onExitRequested: () async {
        await _runtime.close();
        return AppExitResponse.exit;
      },
    );
    final model = request.modelPath;
    if (model == null || request.modelId == null || request.maxTokens <= 0) {
      yield InferenceResponse.error('Missing model or invalid generation limit.');
      return;
    }
    final file = File(model);
    final bytes = await file.open();
    try {
      if ((await bytes.read(4)).join(',') != '71,71,85,70') {
        yield InferenceResponse.error('Invalid GGUF model.');
        return;
      }
    } finally { await bytes.close(); }
    String? gpuExecutable;
    String? gpuDevice;
    if (Platform.isWindows && !_gpuUnavailable &&
        WindowsLlamaRuntime.isModernWindows(Platform.operatingSystemVersion) &&
        AssistantWindowsGpuPolicy.supports(request.modelId!)) {
      final candidate = p.join(p.dirname(executable), '..', 'runtime-vulkan', 'llama-server.exe');
      if (File(candidate).existsSync()) {
        final listing = await _gpuDevices.get(() => _listGpuDevices(candidate),
            usable: (value) => WindowsVulkanDevice.select(value, modelBytes: file.lengthSync()) != null);
        if (cancellationToken.isCancelled) {
          yield InferenceResponse.error('Inference cancelled.', state: InferenceTerminalState.cancelled);
          return;
        }
        gpuDevice = WindowsVulkanDevice.select(listing ?? '', modelBytes: await file.length());
        if (gpuDevice != null) {
          gpuExecutable = candidate;
        } else {
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] stage=request reason=no_eligible_device_or_headroom retry_after_s=30');
        }
      }
    }
    final prompt = LocalPromptTemplates.compose(modelId: request.modelId!,
        prompt: request.prompt, systemPrompt: request.systemPrompt, context: request.context,
        preserveHistoryPrefix: Platform.isWindows,
        assistantModelCompatibility: Platform.isWindows);
    final metadata = SamplingMetadata.fromPrompt(prompt);
    final text = StringBuffer();
    var chunks = 0;
    try {
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] backend=${gpuDevice ?? 'cpu'}');
      final output = _runtime.generate(executable: gpuExecutable ?? executable, modelPath: model,
        sessionId: request.sessionId, prompt: metadata.stripFrom(prompt),
        maxTokens: request.maxTokens, temperature: metadata.temperature ?? request.temperature,
        topP: metadata.topP ?? request.topP,
        repeatPenalty: metadata.repeatPenalty ?? request.repeatPenalty,
        threads: (Platform.numberOfProcessors ~/ 2).clamp(1, 8), cancellation: cancellationToken,
        device: gpuDevice,
        rejectTokenLimit: Platform.isWindows,
        batchSize: gpuDevice == null && Platform.isWindows && LocalInferenceModelIds.resolveTemplate(request.modelId!) ==
            LocalInferenceModelIds.templateNemotron ? 128 : null,
        onPromptUsage: (cached, evaluated) => RuntimeEventLog.instance.emit(
          '[ASSISTANT_LOCAL_CACHE] cached_tokens=$cached evaluated_tokens=$evaluated'),
      );
      final answer = Platform.isWindows &&
              LocalPromptTemplates.usesDeepSeekR1AssistantOutput(request.modelId!)
          ? AssistantReasoningOutput.answerAfterInitialReasoning(output)
          : output;
      await for (final chunk in CompletionOutput.visible(answer)) {
        if (chunk.isEmpty) continue;
        text.write(chunk);
        chunks++;
        yield InferenceResponse.token(text: chunk, model: request.modelId);
      }
      if (cancellationToken.isCancelled) throw StateError('Inference cancelled.');
      if (text.toString().trim().isEmpty) throw StateError('No generated text.');
      markRuntimeVerified(model);
      yield InferenceResponse.finalChunk(text: text.toString(),
          tokensGenerated: (text.length / 4).ceil(), model: request.modelId);
    } catch (error) {
      clearRuntimeVerification();
      if (cancellationToken.isCancelled) {
        yield InferenceResponse.error('Inference cancelled.', state: InferenceTerminalState.cancelled);
      } else if (error is ResidentRuntimeBusy) {
        yield InferenceResponse.error('Local inference is already running.');
      } else if (error is ResidentGenerationLimitReached) {
        // A token cap is not an unavailable model or GPU. Preserve the backend.
        yield InferenceResponse.error('The response reached its generation limit before completion.');
      } else if (error is AssistantReasoningIncomplete) {
        // A reasoning budget/format failure is not an unavailable GPU/model.
        // Do not silently retry another backend or rank thoughts as an answer.
        yield InferenceResponse.error('The response ended before a final answer. The reasoning budget may be insufficient.');
      } else if (chunks == 0) {
        if (gpuExecutable != null) {
          _gpuUnavailable = true;
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] status=unavailable action=resident_cpu_fallback');
          yield* streamInference(request: request, cancellationToken: cancellationToken);
          return;
        }
        _unavailable = true;
        RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_CACHE] status=unavailable action=cli_fallback');
        yield* _delegate.streamInference(request: request, cancellationToken: cancellationToken);
      } else {
        yield InferenceResponse.error('Local inference interrupted before completion.');
      }
    }
  }
}

