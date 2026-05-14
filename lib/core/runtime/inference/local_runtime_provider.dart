import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/foundation.dart';

class LocalRuntimeProvider implements RuntimeInferenceProvider {
  static const Set<String> _mobileValidatedModelIds = <String>{
    LocalInferenceModelIds.gemma2b,
    LocalInferenceModelIds.gemma2_2bIt,
    LocalInferenceModelIds.llama1b,
    LocalInferenceModelIds.deepSeekR1_1_5b,
    LocalInferenceModelIds.qwen3_1_7b,
  };

  static const Set<String> _desktopValidatedModelIds = <String>{
    ..._mobileValidatedModelIds,
  };

  String? _verifiedModelPath;

  @protected
  void markRuntimeVerified(String modelPath) {
    _verifiedModelPath = modelPath;
  }

  @protected
  void clearRuntimeVerification() {
    _verifiedModelPath = null;
  }

  @protected
  bool hasVerifiedRuntimeForModel(String modelPath) =>
      _verifiedModelPath != null && _verifiedModelPath == modelPath;

  bool supportsModel(AiModel model) {
    if (!_isModelAllowedOnPlatform(model.effectiveRuntimeModelId)) return false;
    return model.validationStatus == ModelValidationStatus.validatedOk;
  }

  Future<LocalRuntimeState> validateRuntime({AiModel? selectedModel}) async {
    if (selectedModel == null ||
        !selectedModel.isDownloaded ||
        selectedModel.localPath == null ||
        selectedModel.localPath!.trim().isEmpty) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Download and select a local model to enable on-device AI.',
      );
    }

    if (selectedModel.validationStatus == ModelValidationStatus.downloading) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.loading,
        message: 'Local model is still downloading.',
      );
    }

    if (selectedModel.validationStatus == ModelValidationStatus.invalidModel) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Selected model file is not a valid GGUF runtime model.',
      );
    }

    if (selectedModel.validationStatus == ModelValidationStatus.missingFile) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Selected model file is missing from device storage.',
      );
    }

    final hasValidGgufHeader =
        await Isolate.run(() => _hasGgufHeader(selectedModel.localPath!));
    if (!hasValidGgufHeader) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Selected model file is missing from device storage.',
      );
    }

    if (!supportsModel(selectedModel)) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Selected model is not supported by the local runtime.',
      );
    }

    if (hasVerifiedRuntimeForModel(selectedModel.localPath!)) {
      return LocalRuntimeState(
        status: LocalRuntimeStatus.ready,
        message: '${selectedModel.displayName} verified for local inference.',
      );
    }

    return LocalRuntimeState(
      status: LocalRuntimeStatus.runtimeUnavailable,
      message:
          '${selectedModel.displayName} is present, but local inference is not proven yet. '
          'Run Runtime Self-Test or send a prompt to verify token streaming.',
    );
  }

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();

    () async {
      try {
        final modelPath = request.modelPath;
        final modelId = request.modelId;

        if (modelPath == null || modelPath.isEmpty || modelId == null) {
          clearRuntimeVerification();
          controller.add(InferenceResponse.error('Missing local model path.'));
          await controller.close();
          return;
        }

        if (!_isModelAllowedOnPlatform(modelId)) {
          clearRuntimeVerification();
          controller.add(
            InferenceResponse.error(
              'Selected model is not validated for runtime execution on this platform.',
            ),
          );
          await controller.close();
          return;
        }

        final isValidModelFile =
            await Isolate.run(() => _hasGgufHeader(modelPath));
        if (!isValidModelFile) {
          clearRuntimeVerification();
          controller.add(InferenceResponse.error(
            'Selected model file is missing or invalid GGUF.',
          ));
          await controller.close();
          return;
        }

        final executable = _resolveLlamaExecutable();
        final args = _buildArgs(request);
        final stderrBuffer = StringBuffer();
        final fullText = StringBuffer();

        Process? process;
        StreamSubscription<String>? stdoutSub;
        StreamSubscription<String>? stderrSub;
        var estimatedTokenCount = 0;

        try {
          process = await Process.start(executable, args);
        } on ProcessException catch (e) {
          clearRuntimeVerification();
          controller.add(
            InferenceResponse.error(
              'Failed to start llama.cpp runtime process: ${e.message}',
            ),
          );
          await controller.close();
          return;
        } catch (e) {
          clearRuntimeVerification();
          controller.add(InferenceResponse.error('Failed to start inference: $e'));
          await controller.close();
          return;
        }

        cancellationToken.onCancel(() {
          process?.kill(ProcessSignal.sigterm);
        });

        stdoutSub = process.stdout
            .transform(utf8.decoder)
            .listen(
          (chunk) {
            // Stream callbacks run sequentially on this isolate event loop.
            if (chunk.isEmpty) return;
            fullText.write(chunk);
            estimatedTokenCount += _estimateTokenCount(chunk);
            controller.add(InferenceResponse.token(text: chunk, model: modelId));
          },
          onError: (Object error) {
            // Log stdout decode errors (e.g. malformed UTF-8) but keep the
            // stream alive; the process exit code will handle final state.
            debugPrint('[$_localProviderTag] stdout decode error: $error');
          },
          cancelOnError: false,
        );

        stderrSub = process.stderr
            .transform(utf8.decoder)
            .listen(
          stderrBuffer.write,
          onError: (Object error) {
            debugPrint('[$_localProviderTag] stderr decode error: $error');
          },
          cancelOnError: false,
        );

        final exitCode = await process.exitCode;
        await stdoutSub.cancel();
        await stderrSub.cancel();

        if (cancellationToken.isCancelled) {
          clearRuntimeVerification();
          controller.add(InferenceResponse.error(
            'Inference cancelled.',
            state: InferenceTerminalState.cancelled,
          ));
          await controller.close();
          return;
        }

        if (exitCode != 0 && fullText.isEmpty) {
          clearRuntimeVerification();
          final stderr = stderrBuffer.toString().trim();
          controller.add(
            InferenceResponse.error(
              stderr.isEmpty
                  ? 'llama.cpp runtime failed with exit code $exitCode.'
                  : stderr,
            ),
          );
          await controller.close();
          return;
        }

        markRuntimeVerified(modelPath);
        controller.add(
          InferenceResponse.finalChunk(
            text: fullText.toString(),
            tokensGenerated: estimatedTokenCount,
            model: modelId,
          ),
        );
        await controller.close();
      } catch (error, stackTrace) {
        clearRuntimeVerification();
        // Unexpected exception: ensure the StreamController is always closed
        // so consumers are never left waiting indefinitely.
        debugPrint('[$_localProviderTag] unexpected inference error: $error\n$stackTrace');
        if (!controller.isClosed) {
          controller.add(
            InferenceResponse.error('Local runtime internal error: $error'),
          );
          await controller.close();
        }
      }
    }();

    return controller.stream;
  }

  static const String _localProviderTag = 'LOCAL_RUNTIME';

  bool _isModelAllowedOnPlatform(String modelId) {
    final allowed = _isDesktopPlatform()
        ? _desktopValidatedModelIds
        : _mobileValidatedModelIds;
    return allowed.contains(modelId);
  }

  String _resolveLlamaExecutable() {
    final envPath = Platform.environment['LLAMA_CPP_EXECUTABLE'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      return envPath.trim();
    }
    return 'llama-cli';
  }

  List<String> _buildArgs(InferenceRequest request) {
    final prompt = _composePrompt(request);
    return <String>[
      '-m',
      request.modelPath!,
      '-p',
      prompt,
      '-n',
      request.maxTokens.toString(),
      '--temp',
      request.temperature.toString(),
      '--no-display-prompt',
      '--log-disable', // suppress llama.cpp verbose logging to stderr
    ];
  }

  String _composePrompt(InferenceRequest request) {
    return LocalPromptTemplates.compose(
      modelId: request.modelId ?? '',
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  static bool _hasGgufHeader(String modelPath) {
    final file = File(modelPath);
    if (!file.existsSync()) return false;
    RandomAccessFile? accessFile;
    try {
      accessFile = file.openSync(mode: FileMode.read);
      final header = accessFile.readSync(4);
      if (header.length < 4) return false;
      return header[0] == 0x47 &&
          header[1] == 0x47 &&
          header[2] == 0x55 &&
          header[3] == 0x46;
    } finally {
      accessFile?.closeSync();
    }
  }

  int _estimateTokenCount(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return 0;
    return cleaned.split(RegExp(r'\s+')).length;
  }

  static bool _isDesktopPlatform() =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}
