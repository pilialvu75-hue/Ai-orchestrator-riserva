import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/completion_output.dart';
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
    final prompt = LocalPromptTemplates.compose(modelId: request.modelId!,
        prompt: request.prompt, systemPrompt: request.systemPrompt, context: request.context,
        preserveHistoryPrefix: Platform.isWindows);
    final metadata = SamplingMetadata.fromPrompt(prompt);
    final text = StringBuffer();
    var chunks = 0;
    try {
      final output = _runtime.generate(executable: executable, modelPath: model,
        sessionId: request.sessionId, prompt: metadata.stripFrom(prompt),
        maxTokens: request.maxTokens, temperature: metadata.temperature ?? request.temperature,
        topP: metadata.topP ?? request.topP,
        repeatPenalty: metadata.repeatPenalty ?? request.repeatPenalty,
        threads: (Platform.numberOfProcessors ~/ 2).clamp(1, 8), cancellation: cancellationToken,
        batchSize: Platform.isWindows && LocalInferenceModelIds.resolveTemplate(request.modelId!) ==
            LocalInferenceModelIds.templateNemotron ? 128 : null,
        onPromptUsage: (cached, evaluated) => RuntimeEventLog.instance.emit(
          '[ASSISTANT_LOCAL_CACHE] cached_tokens=$cached evaluated_tokens=$evaluated'),
      );
      await for (final chunk in CompletionOutput.visible(output)) {
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
      } else if (chunks == 0) {
        _unavailable = true;
        RuntimeEventLog.instance.emit('[ASSISTANT_LOCAL_CACHE] status=unavailable action=cli_fallback');
        yield* _delegate.streamInference(request: request, cancellationToken: cancellationToken);
      } else {
        yield InferenceResponse.error('Local inference interrupted before completion.');
      }
    }
  }
}
