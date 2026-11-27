import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show visibleForTesting;
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
import 'package:ai_orchestrator/core/runtime/inference/windows_generation_metrics.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_memory_guard.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/sampling_metadata.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_llama_runtime.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_vulkan_device.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_cuda_device.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_gpu_probe_cache.dart';

/// Assistant-only warm desktop runtime. Workshop and diagnostics retain their
/// canonical provider. Unsupported platforms and startup failures use the CLI.
final class AssistantResidentLocalRuntimeProvider extends LocalRuntimeProvider {
  AssistantResidentLocalRuntimeProvider({required LocalRuntimeProvider delegate,
      ResidentCompletionRuntime? runtime, String? Function()? executable,
      bool Function()? isWindowsHost, bool Function()? isModernWindowsHost,
      Future<String?> Function(String executable)? gpuDeviceListing,
      bool Function()? cudaQaEnabled})
      : _delegate = delegate, _runtime = runtime ?? ResidentCompletionRuntime(
          windowsResources: Platform.isWindows ? ResourceMonitor.instance : null),
        _executable = executable ?? _bundledServer,
        _isWindowsHost = isWindowsHost ?? _platformIsWindows,
        _isModernWindowsHost = isModernWindowsHost ?? _platformIsModernWindows,
        _gpuDeviceListing = gpuDeviceListing,
        _cudaQaEnabled = cudaQaEnabled ?? _defaultCudaQaEnabled;

  static bool _platformIsWindows() => Platform.isWindows;

  // A stale runtime-cuda directory from a Beta must never affect Stable.
  // Only a deliberately compiled Windows CUDA QA build may select it.
  static bool _defaultCudaQaEnabled() => const bool.fromEnvironment(
        'AIVEXUS_WINDOWS_CUDA_QA', defaultValue: false);
  static bool _platformIsModernWindows() => Platform.isWindows &&
      WindowsLlamaRuntime.isModernWindows(Platform.operatingSystemVersion);

  final LocalRuntimeProvider _delegate;
  final ResidentCompletionRuntime _runtime;
  final String? Function() _executable;
  final bool Function() _isWindowsHost;
  final bool Function() _isModernWindowsHost;
  final Future<String?> Function(String executable)? _gpuDeviceListing;
  final bool Function() _cudaQaEnabled;
  AppLifecycleListener? _lifecycle;
  bool _unavailable = false;
  bool _gpuUnavailable = false;
  bool _cudaUnavailable = false;
  final _gpuDevices = WindowsGpuProbeCache();
  final _cudaDevices = WindowsGpuProbeCache();
  Future<void>? _preparation;

  /// Prepare only the measured Windows GPU route while the app opens.
  /// This does not verify inference or populate the conversation cache.
  Future<void> prepareSelectedModel(AiModel model) {
    return _preparation ??= _prepareSelectedModel(model);
  }

  Future<void> _prepareSelectedModel(AiModel model) async {
    if (!_isWindowsHost() || !_isModernWindowsHost() || _gpuUnavailable ||
        !AssistantWindowsGpuPolicy.supportsAutomaticPreparation(model.effectiveRuntimeModelId)) return;
    final cpuExecutable = _executable();
    final modelPath = model.localPath;
    if (cpuExecutable == null || modelPath == null || !File(modelPath).existsSync()) return;
    final watch = Stopwatch()..start();
    final modelBytes = await File(modelPath).length();
    final cudaCandidate = p.join(p.dirname(cpuExecutable), '..', 'runtime-cuda', 'llama-server.exe');
    if (_cudaQaEnabled() && !_cudaUnavailable && File(cudaCandidate).existsSync()) {
      final cudaListing = await _cudaDevices.get(() => _listGpuDevices(cudaCandidate),
          usable: (value) => WindowsCudaDevice.select(value, modelBytes: modelBytes) != null);
      final cudaDevice = WindowsCudaDevice.select(cudaListing ?? '', modelBytes: modelBytes);
      if (cudaDevice != null) {
        try {
          await _runtime.prepare(executable: cudaCandidate, modelPath: modelPath,
              sessionId: 'default', threads: (Platform.numberOfProcessors ~/ 2).clamp(1, 8),
              device: cudaDevice, batchSize: 512, ubatchSize: 256, flashAttention: true);
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_PREPARE] backend=cuda status=ready elapsed_ms=${watch.elapsedMilliseconds}');
          return;
        } on WindowsMemoryPressure {
          RuntimeEventLog.instance.emit('[WINDOWS_MEMORY_GUARD] stage=prepare action=stop');
          return;
        } catch (_) {
          _cudaUnavailable = true;
        }
      }
    }
    final candidate = p.join(p.dirname(cpuExecutable), '..', 'runtime-vulkan', 'llama-server.exe');
    if (!File(candidate).existsSync()) return;
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
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_PREPARE] backend=vulkan status=ready elapsed_ms=${watch.elapsedMilliseconds}');
    } catch (_) {
      RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_PREPARE] status=failed action=normal_request_startup');
    }
  }

  Future<String?> _listGpuDevices(String executable) async {
    final injected = _gpuDeviceListing;
    if (injected != null) return injected(executable);
    Process? probe;
    try {
      probe = await Process.start(executable, ['--list-devices']);
      // llama.cpp builds can emit --list-devices to either stdout or stderr.
      // Drain both pipes concurrently to avoid blocking if either fills up.
      final stdout = probe.stdout.transform(utf8.decoder).join();
      final stderr = probe.stderr.transform(utf8.decoder).join();
      final code = await probe.exitCode.timeout(const Duration(seconds: 15));
      final listing = await stdout;
      final diagnosticListing = await stderr;
      RuntimeEventLog.instance.emit(
        '[ASSISTANT_LOCAL_GPU_PROBE] '
        'backend=${p.basename(p.dirname(executable))} '
        'exit_code=$code stdout_chars=${listing.length} '
        'stderr_chars=${diagnosticListing.length}',
      );
      return code == 0 ? '$listing\n$diagnosticListing' : null;
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
      return bundledWindowsServerFor(
        appDir,
        modernWindows: WindowsLlamaRuntime.isModernWindows(
          Platform.operatingSystemVersion,
        ),
        cudaQaEnabled: _defaultCudaQaEnabled(),
      );
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final file = p.join(appDir, 'llama-server');
      return File(file).existsSync() ? file : null;
    }
    return null;
  }

  /// Resolve the exact locally bundled resident server, without relying on
  /// PATH, the working directory or another locally installed application.
  /// The extra QA-only fallback is needed because the unsigned CUDA owner
  /// release intentionally ships runtime-cuda but not runtime-modern.
  @visibleForTesting
  static String? bundledWindowsServerFor(
    String appDir, {
    required bool modernWindows,
    required bool cudaQaEnabled,
    bool Function(String)? fileExists,
  }) {
    if (!modernWindows) return null;
    final exists = fileExists ?? (String file) => File(file).existsSync();
    final modern = p.join(appDir, 'runtime-modern', 'llama-server.exe');
    if (exists(modern)) return modern;
    if (cudaQaEnabled) {
      final cuda = p.join(appDir, 'runtime-cuda', 'llama-server.exe');
      if (exists(cuda)) return cuda;
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
    // Scope presentation telemetry to this attempt. A recursive fallback
    // obtains a newer id, so the outer finally cannot overwrite it.
    final metrics = Platform.isWindows ? WindowsGenerationMetrics.instance : null;
    final metricId = metrics?.begin();
    try {
    // Use the ordinary resident CUDA/Vulkan/CPU route also for Qwen 2.5 3B.
    // Existing guarded CLI recovery remains available on actual failures.
    final executable = _unavailable ? null : _executable();
    if (executable == null) {
      if (metricId != null) metrics?.selectRoute(metricId, 'process_cli');
      RuntimeEventLog.instance.emit(
        '[ASSISTANT_LOCAL_ROUTE] backend=process_cli reason=resident_server_missing_or_unavailable',
      );
      await for (final response in _delegate.streamInference(
          request: request, cancellationToken: cancellationToken)) {
        if (metricId != null) {
          if (!response.isFinal && !response.isError && response.text.isNotEmpty) {
            metrics?.firstText(metricId);
          }
          if (response.isFinal) {
            metrics?.finish(metricId, success: !response.isError &&
                response.terminalState == InferenceTerminalState.success);
          }
        }
        yield response;
      }
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
    String? gpuBackend;
    if (_isWindowsHost() && _cudaQaEnabled() && !_cudaUnavailable &&
        _isModernWindowsHost() &&
        AssistantWindowsGpuPolicy.supports(request.modelId!)) {
      final candidate = p.join(p.dirname(executable), '..', 'runtime-cuda', 'llama-server.exe');
      if (File(candidate).existsSync()) {
        final listing = await _cudaDevices.get(() => _listGpuDevices(candidate),
            usable: (value) => WindowsCudaDevice.select(value, modelBytes: file.lengthSync()) != null);
        if (cancellationToken.isCancelled) {
          yield InferenceResponse.error('Inference cancelled.', state: InferenceTerminalState.cancelled);
          return;
        }
        gpuDevice = WindowsCudaDevice.select(listing ?? '', modelBytes: await file.length());
        if (gpuDevice != null) {
          gpuExecutable = candidate;
          gpuBackend = 'cuda';
        } else {
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] backend=cuda stage=request reason=no_eligible_device_or_headroom retry_after_s=30');
        }
      }
    }
    if (gpuDevice == null && _isWindowsHost() && !_gpuUnavailable &&
        _isModernWindowsHost() &&
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
          gpuBackend = 'vulkan';
        } else {
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] backend=vulkan stage=request reason=no_eligible_device_or_headroom retry_after_s=30');
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
      RuntimeEventLog.instance.emit(
        '[ASSISTANT_LOCAL_ROUTE] backend=${gpuBackend ?? 'resident_cpu'} '
        'engine=${p.basename(p.dirname(gpuExecutable ?? executable))} '
        'device=${gpuDevice ?? 'none'}',
      );
      if (metricId != null) metrics?.selectRoute(metricId, gpuBackend ?? 'resident_cpu');
      final output = _runtime.generate(executable: gpuExecutable ?? executable, modelPath: model,
        sessionId: request.sessionId, prompt: metadata.stripFrom(prompt),
        maxTokens: request.maxTokens, temperature: metadata.temperature ?? request.temperature,
        topP: metadata.topP ?? request.topP,
        repeatPenalty: metadata.repeatPenalty ?? request.repeatPenalty,
        threads: (Platform.numberOfProcessors ~/ 2).clamp(1, 8), cancellation: cancellationToken,
        device: gpuDevice,
        rejectTokenLimit: Platform.isWindows,
        batchSize: gpuBackend == 'cuda'
            ? 512
            : (gpuDevice == null && Platform.isWindows &&
                    LocalInferenceModelIds.resolveTemplate(request.modelId!) ==
                        LocalInferenceModelIds.templateNemotron
                ? 128
                : null),
        ubatchSize: gpuBackend == 'cuda' ? 256 : null,
        flashAttention: gpuBackend == 'cuda',
        onPromptUsage: (cached, evaluated) => RuntimeEventLog.instance.emit(
          '[ASSISTANT_LOCAL_CACHE] cached_tokens=$cached evaluated_tokens=$evaluated'),
      );
      final Stream<String> answer;
      if (Platform.isWindows &&
          LocalPromptTemplates.usesDeepSeekR1AssistantOutput(request.modelId!)) {
        answer = AssistantReasoningOutput.answerAfterInitialReasoning(output);
      } else if (_isWindowsHost() &&
          LocalInferenceModelIds.resolveTemplate(request.modelId!) ==
              LocalInferenceModelIds.templateQwen &&
          !AssistantReasoningOutput.requestsLiteralThinkTags(request.prompt)) {
        answer = AssistantReasoningOutput.answerAfterOptionalInitialReasoning(output);
      } else {
        answer = output;
      }
      await for (final chunk in CompletionOutput.visible(answer)) {
        if (chunk.isEmpty) continue;
        if (chunks == 0 && metricId != null) metrics?.firstText(metricId);
        text.write(chunk);
        chunks++;
        yield InferenceResponse.token(text: chunk, model: request.modelId);
      }
      if (cancellationToken.isCancelled) throw StateError('Inference cancelled.');
      if (text.toString().trim().isEmpty) throw StateError('No generated text.');
      markRuntimeVerified(model);
      if (metricId != null) metrics?.finish(metricId, success: true, stats: _runtime.lastGenerationMetrics);
      yield InferenceResponse.finalChunk(text: text.toString(),
          tokensGenerated: (text.length / 4).ceil(), model: request.modelId);
    } catch (error) {
      clearRuntimeVerification();
      if (error is WindowsMemoryPressure) {
        RuntimeEventLog.instance.emit('[WINDOWS_MEMORY_GUARD] stage=generation action=stop_no_fallback');
        yield InferenceResponse.error(WindowsMemoryPressure.message);
      } else if (cancellationToken.isCancelled) {
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
          if (gpuBackend == 'cuda') {
            _cudaUnavailable = true;
          } else {
            _gpuUnavailable = true;
          }
          RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_GPU] backend=${gpuBackend ?? 'unknown'} status=unavailable action=resident_fallback');
          if (metricId != null) metrics?.finish(metricId, success: false);
          yield* streamInference(request: request, cancellationToken: cancellationToken);
          return;
        }
        _unavailable = true;
        if (metricId != null) metrics?.selectRoute(metricId, 'process_cli');
        RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_CACHE] status=unavailable action=cli_fallback');
        await for (final response in _delegate.streamInference(
          request: request, cancellationToken: cancellationToken)) {
        if (metricId != null) {
          if (!response.isFinal && !response.isError && response.text.isNotEmpty) {
            metrics?.firstText(metricId);
          }
          if (response.isFinal) {
            metrics?.finish(metricId, success: !response.isError &&
                response.terminalState == InferenceTerminalState.success);
          }
        }
        yield response;
      }
      } else {
        yield InferenceResponse.error('Local inference interrupted before completion.');
      }
    }
    } finally {
      if (metricId != null) metrics?.finish(metricId, success: false);
    }
  }
}

