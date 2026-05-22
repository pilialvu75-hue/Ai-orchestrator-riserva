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
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/foundation.dart';

class LocalRuntimeProvider implements RuntimeInferenceProvider {
  LocalRuntimeProvider({
    bool Function()? developerModeProvider,
  }) : _developerModeProvider =
            developerModeProvider ?? (() => kDebugMode);

  static const String _localProviderTag = 'LOCAL_RUNTIME';

  static const int _maxModelFileSizeBytes =
      12 * 1024 * 1024 * 1024; // 12GB safety cap

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

  final bool Function() _developerModeProvider;

  bool get _isDeveloperMode => _developerModeProvider();

  String? _verifiedModelPath;

  String _normalizeModelPath(String modelPath) {
    final trimmed = modelPath.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      return File(trimmed).absolute.path;
    } catch (error) {
      debugPrint(
        '[$_localProviderTag] modelPath normalization fallback for "$trimmed": $error',
      );
      return trimmed;
    }
  }

  @protected
  void markRuntimeVerified(String modelPath) {
    _verifiedModelPath = _normalizeModelPath(modelPath);
  }

  @protected
  void clearRuntimeVerification() {
    _verifiedModelPath = null;
  }

  @protected
  bool hasVerifiedRuntimeForModel(String modelPath) =>
      _verifiedModelPath != null &&
      _verifiedModelPath == _normalizeModelPath(modelPath);

  bool isRuntimeVerified({String? modelPath}) {
    if (modelPath == null || modelPath.trim().isEmpty) {
      return _verifiedModelPath != null;
    }
    return hasVerifiedRuntimeForModel(modelPath);
  }

  int get activeLifecycleTransitionId => -1;

  String get lifecycleRuntimeStateName => 'unknown';

  void recordVerificationSuccess({
    required String modelPath,
    String source = 'runtime',
  }) {
    final normalizedModelPath = _normalizeModelPath(modelPath);
    markRuntimeVerified(modelPath);
    debugPrint(
      '[$_localProviderTag] [VERIFICATION_MARK_SET] source=$source',
    );
    debugPrint(
      '[$_localProviderTag] [VERIFIED_MODEL_PATH=$normalizedModelPath]',
    );
    debugPrint(
      '[$_localProviderTag] verification marked source=$source modelPath=$normalizedModelPath',
    );
  }

  bool supportsModel(AiModel model) {
    final modelId = model.effectiveRuntimeModelId;

    final allowed = _isModelAllowedOnPlatform(modelId);

    if (!allowed) {
      if (_isDeveloperMode) {
        const msg =
            '[VALIDATION] developer_mode=true: allowing custom/unvalidated model';

        debugPrint(
          '[$_localProviderTag] $msg modelId=$modelId',
        );

        RuntimeEventLog.instance.emit(
          '$msg modelId=$modelId',
        );

        return model.localPath != null &&
            model.localPath!.isNotEmpty &&
            model.isDownloaded;
      }

      return false;
    }

    return model.validationStatus ==
            ModelValidationStatus.validatedOk ||
        (_isDeveloperMode && model.isDownloaded);
  }

  Future<LocalRuntimeState> validateRuntime({
    AiModel? selectedModel,
  }) async {
    if (selectedModel == null) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'No local model selected.',
      );
    }

    if (!selectedModel.isDownloaded) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Model is not downloaded.',
      );
    }

    final modelPath = selectedModel.localPath;

    if (modelPath == null || modelPath.trim().isEmpty) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Model path is empty.',
      );
    }

    final exists = await Isolate.run(
      () => File(modelPath).existsSync(),
    );

    if (!exists) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Model file missing from storage.',
      );
    }

    final fileSize = await Isolate.run(
      () => File(modelPath).lengthSync(),
    );

    if (fileSize <= 0 ||
        fileSize > _maxModelFileSizeBytes) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Invalid model file size.',
      );
    }

    final hasValidGgufHeader =
        await Isolate.run(
      () => _hasGgufHeader(modelPath),
    );

    if (!hasValidGgufHeader) {
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Invalid GGUF model header.',
      );
    }

    if (!supportsModel(selectedModel)) {
      if (_isDeveloperMode) {
        return const LocalRuntimeState(
          status: LocalRuntimeStatus.runtimeUnavailable,
          message:
              '[DEVELOPER_MODE] Unvalidated model accepted.',
        );
      }

      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message:
            'Selected model is not supported.',
      );
    }

    if (hasVerifiedRuntimeForModel(modelPath)) {
      return LocalRuntimeState(
        status: LocalRuntimeStatus.ready,
        message:
            '${selectedModel.displayName} ready.',
      );
    }

    return LocalRuntimeState(
      status: LocalRuntimeStatus.runtimeUnavailable,
      message:
          '${selectedModel.displayName} detected but runtime not yet verified.',
    );
  }

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    // 1. BLOCCO IMMEDIATO: Se è Android, esce subito senza fare NIENTE altro
    if (Platform.isAndroid) {
      debugPrint('[$_localProviderTag] Android detected: Processo CLI bloccato.');
      final controller = StreamController<InferenceResponse>();
      controller.add(InferenceResponse.error('Esecuzione locale tramite CLI non supportata su Android.'));
      controller.close();
      return controller.stream;
    }

    final controller = StreamController<InferenceResponse>();

    () async {
      try {
        final modelPath = request.modelPath;
        final modelId = request.modelId;

        debugPrint(
          '[$_localProviderTag] streamInference start model=$modelId',
        );

        if (modelPath == null ||
            modelPath.isEmpty ||
            modelId == null) {
          clearRuntimeVerification();

          controller.add(
            InferenceResponse.error(
              'Missing local model path.',
            ),
          );

          await controller.close();
          return;
        }

        final modelExists = await Isolate.run(
          () => File(modelPath).existsSync(),
        );

        if (!modelExists) {
          clearRuntimeVerification();

          controller.add(
            InferenceResponse.error(
              'Model file not found.',
            ),
          );

          await controller.close();
          return;
        }

        final isValidModelFile =
            await Isolate.run(
          () => _hasGgufHeader(modelPath),
        );

        if (!isValidModelFile) {
          clearRuntimeVerification();

          controller.add(
            InferenceResponse.error(
              'Invalid GGUF model.',
            ),
          );

          await controller.close();
          return;
        }

        final executable =
            _resolveLlamaExecutable();

        final args = _buildArgs(request);

        debugPrint(
          '[$_localProviderTag] executable=$executable',
        );

        final stderrBuffer = StringBuffer();
        final fullText = StringBuffer();

        Process? process;

        StreamSubscription<String>? stdoutSub;
        StreamSubscription<String>? stderrSub;

        var estimatedTokenCount = 0;

        try {
          process = await Process.start(
            executable,
            args,
          );
        } on ProcessException catch (e) {
          clearRuntimeVerification();

          controller.add(
            InferenceResponse.error(
              'Failed to start llama.cpp: ${e.message}',
            ),
          );

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
            if (chunk.isEmpty) return;

            fullText.write(chunk);

            estimatedTokenCount +=
                _estimateTokenCount(chunk);

            controller.add(
              InferenceResponse.token(
                text: chunk,
                model: modelId,
              ),
            );
          },
          onError: (Object error) {
            debugPrint(
              '[$_localProviderTag] stdout error: $error',
            );
          },
          cancelOnError: false,
        );

        stderrSub = process.stderr
            .transform(utf8.decoder)
            .listen(
          (chunk) {
            stderrBuffer.write(chunk);

            debugPrint(
              '[$_localProviderTag][stderr] $chunk',
            );
          },
          onError: (Object error) {
            debugPrint(
              '[$_localProviderTag] stderr error: $error',
            );
          },
          cancelOnError: false,
        );

        final exitCode = await process.exitCode;

        await stdoutSub.cancel();
        await stderrSub.cancel();

        debugPrint(
          '[$_localProviderTag] process exitCode=$exitCode',
        );

        if (cancellationToken.isCancelled) {
          clearRuntimeVerification();

          controller.add(
            InferenceResponse.error(
              'Inference cancelled.',
              state:
                  InferenceTerminalState.cancelled,
            ),
          );

          await controller.close();
          return;
        }

        if (exitCode != 0 &&
            fullText.isEmpty) {
          clearRuntimeVerification();

          final stderr =
              stderrBuffer.toString().trim();

          controller.add(
            InferenceResponse.error(
              stderr.isEmpty
                  ? 'llama.cpp failed with exit code $exitCode'
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
            tokensGenerated:
                estimatedTokenCount,
            model: modelId,
          ),
        );

        await controller.close();
      } catch (error, stackTrace) {
        clearRuntimeVerification();

        debugPrint(
          '[$_localProviderTag] fatal error: $error\n$stackTrace',
        );

        if (!controller.isClosed) {
          controller.add(
            InferenceResponse.error(
              'Local runtime internal error: $error',
            ),
          );

          await controller.close();
        }
      }
    }();

    return controller.stream;
  }

  bool _isModelAllowedOnPlatform(
    String modelId,
  ) {
    final allowed =
        _isDesktopPlatform()
            ? _desktopValidatedModelIds
            : _mobileValidatedModelIds;

    return allowed.contains(modelId);
  }

  String _resolveLlamaExecutable() {
    final envPath =
        Platform.environment[
            'LLAMA_CPP_EXECUTABLE'];

    if (envPath != null &&
        envPath.trim().isNotEmpty) {
      return envPath.trim();
    }

    return 'llama-cli';
  }

  List<String> _buildArgs(
    InferenceRequest request,
  ) {
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
      '--log-disable',
    ];
  }

  String _composePrompt(
    InferenceRequest request,
  ) {
    return LocalPromptTemplates.compose(
      modelId: request.modelId ?? '',
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  static bool _hasGgufHeader(
    String modelPath,
  ) {
    final file = File(modelPath);

    if (!file.existsSync()) {
      return false;
    }

    RandomAccessFile? accessFile;

    try {
      accessFile = file.openSync(
        mode: FileMode.read,
      );

      final header =
          accessFile.readSync(4);

      if (header.length < 4) {
        return false;
      }

      return header[0] == 0x47 &&
          header[1] == 0x47 &&
          header[2] == 0x55 &&
          header[3] == 0x46;
    } finally {
      accessFile?.closeSync();
    }
  }

  int _estimateTokenCount(
    String text,
  ) {
    final cleaned = text.trim();

    if (cleaned.isEmpty) {
      return 0;
    }

    return cleaned
        .split(RegExp(r'\s+'))
        .length;
  }

  static bool _isDesktopPlatform() {
    return Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS;
  }
}
