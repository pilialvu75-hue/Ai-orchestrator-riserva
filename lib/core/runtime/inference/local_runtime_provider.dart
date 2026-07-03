import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/android/models/android_ffi_runtime_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart'; // RIGA 11: UTILIZZATA CON SUCCESSO
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/sampling_metadata.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/foundation.dart';

// Importazione polimorfica per gestire la deviazione nativa FFI su sistemi Android
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';

class LocalRuntimeProvider implements RuntimeInferenceProvider {
  LocalRuntimeProvider({
    bool Function()? developerModeProvider,
  }) : _developerModeProvider =
            developerModeProvider ?? (() => kDebugMode);

  static const String _localProviderTag = 'LOCAL_RUNTIME';

  static const int _maxModelFileSizeBytes =
      12 * 1024 * 1024 * 1024; // 12GB safety cap

  // ——— FIX: Set Mobile con Phi-3.5-mini aggiunto ———
static final Set<String> _mobileValidatedModelIds = {
  ...AndroidFfiRuntimeModelIds.validatedModelIds,
  LocalInferenceModelIds.phi3_5_mini, 
};

static final Set<String> _desktopValidatedModelIds = {
  ...AndroidFfiRuntimeModelIds.validatedModelIds,
};
// —————————————————————————————————————————————————

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
      RuntimeEventLog.instance.emit('[MODEL_FOUND] status=missing');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=no_local_model_selected');
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'No local model selected.',
      );
    }

    if (!selectedModel.isDownloaded) {
      RuntimeEventLog.instance.emit('[MODEL_FOUND] status=not_downloaded modelId=${selectedModel.id}');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=model_not_downloaded modelId=${selectedModel.id}');
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Model file not downloaded.',
      );
    }

    final modelPath = selectedModel.localPath;

    if (modelPath == null || modelPath.trim().isEmpty) {
      RuntimeEventLog.instance.emit('[MODEL_FOUND] status=missing_path modelId=${selectedModel.id}');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=model_path_empty modelId=${selectedModel.id}');
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.modelMissing,
        message: 'Model path is empty.',
      );
    }

    final exists = await Isolate.run(
      () => File(modelPath).existsSync(),
    );

    if (!exists) {
      RuntimeEventLog.instance.emit('[MODEL_FOUND] status=missing_file modelId=${selectedModel.id} path=$modelPath');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=model_file_missing modelId=${selectedModel.id}');
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
      RuntimeEventLog.instance.emit('[MODEL_FOUND] status=invalid_size modelId=${selectedModel.id} size_bytes=$fileSize');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=invalid_model_size modelId=${selectedModel.id}');
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
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=invalid_gguf_header modelId=${selectedModel.id}');
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message: 'Invalid GGUF model header.',
      );
    }

    if (!supportsModel(selectedModel)) {
      if (_isDeveloperMode) {
        RuntimeEventLog.instance.emit('[MODEL_COMPATIBLE] modelId=${selectedModel.id} compatible=false developer_mode=true');
        return const LocalRuntimeState(
          status: LocalRuntimeStatus.runtimeUnavailable,
          message:
              '[DEVELOPER_MODE] Unvalidated model accepted.',
        );
      }

      RuntimeEventLog.instance.emit('[MODEL_COMPATIBLE] modelId=${selectedModel.id} compatible=false developer_mode=false');
      RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=unsupported_model modelId=${selectedModel.id}');
      return const LocalRuntimeState(
        status: LocalRuntimeStatus.failed,
        message:
            'Selected model is not supported.',
      );
    }

    final gateVerified = hasVerifiedRuntimeForModel(modelPath);
    final gateModelId = selectedModel.effectiveRuntimeModelId;
    final gateMsg = '[AI_RUNTIME_MONITOR] FORENSIC - File: local_runtime_provider.dart'
        ' | Function: validateRuntime()'
        ' | hasVerifiedRuntimeForModel: $gateVerified'
        ' | ModelID: $gateModelId'
        ' | ModelPath: $modelPath'
        ' | _verifiedModelPath: ${_verifiedModelPath ?? 'null'}';
    debugPrint(gateMsg);
    RuntimeEventLog.instance.emit(gateMsg);
    RuntimeEventLog.instance.emit('[MODEL_FOUND] status=present modelId=${selectedModel.id} path=$modelPath');
    RuntimeEventLog.instance.emit('[MODEL_HASH] modelId=${selectedModel.id} hash=${secureForensicHash('${selectedModel.id}:$modelPath:$fileSize')}');
    RuntimeEventLog.instance.emit('[MODEL_RUNTIME] modelId=${selectedModel.id} runtime=${Platform.isAndroid ? 'android_ffi' : 'process_cli'}');

    if (gateVerified) {
      RuntimeEventLog.instance.emit('[MODEL_COMPATIBLE] modelId=${selectedModel.id} compatible=true');
      RuntimeEventLog.instance.emit('[MODEL_READY] modelId=${selectedModel.id}');
      RuntimeEventLog.instance.emit('[VALIDATION_SUCCESS] modelId=${selectedModel.id}');
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
  T  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    // Mantieni il blocco FFI per Android che avevi già
    if (Platform.isAndroid && this is! AndroidFfiRuntimeProvider) {
      final ffiRuntimeElement = AndroidFfiRuntimeProvider(
        developerModeProvider: _developerModeProvider,
      );
      return ffiRuntimeElement.streamInference(
        request: request,
        cancellationToken: cancellationToken,
      );
    }

    final controller = StreamController<InferenceResponse>();

    () async {
      try {
        final modelPath = request.modelPath;
        final modelId = request.modelId;

        if (modelPath == null || modelPath.isEmpty || modelId == null) {
           controller.add(InferenceResponse.error('Missing model path.'));
           await controller.close();
           return;
        }

        final executable = _resolveLlamaExecutable();
        final args = _buildArgs(request);
        Process? process;

        process = await Process.start(executable, args);

        cancellationToken.onCancel(() { process?.kill(ProcessSignal.sigterm); });

        final fullText = StringBuffer();

        process.stdout.transform(utf8.decoder).listen(
          (chunk) {
            fullText.write(chunk);
            
            // --- LOGICA INTERCETTAZIONE "STO CERCANDO" ---
            // Cerchiamo il tag <search> nel buffer in tempo reale
            final searchMatch = RegExp(r'<search>(.*?)</search>').firstMatch(fullText.toString());
            
            if (searchMatch != null) {
              final query = searchMatch.group(1);
              // Invia alla UI il messaggio di ricerca (l'utente vedrà "Sto cercando...")
              controller.add(InferenceResponse.token(
                text: "\n\n🔍 Sto cercando su Internet: '$query'...",
                model: modelId,
              ));
              // IMPORTANTE: Qui potresti voler interrompere lo stream per gestire il tool
              return; 
            }
            // ---------------------------------------------

            controller.add(InferenceResponse.token(text: chunk, model: modelId));
          },
          onError: (Object error) => debugPrint('[$_localProviderTag] error: $error'),
        );

        final exitCode = await process.exitCode;
        await controller.close();

      } catch (error) {
        if (!controller.isClosed) {
          controller.add(InferenceResponse.error('Runtime error: $error'));
          await controller.close();
        }
      }
    }();
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
          RuntimeEventLog.instance.emit('[MODEL_RUNTIME] modelId=${modelId ?? 'none'} runtime=unavailable');
          RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=missing_model_path_or_id');

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
          RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=model_file_missing modelId=$modelId');

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
          RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=invalid_gguf_header modelId=$modelId');

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
        RuntimeEventLog.instance.emit('[MODEL_RUNTIME] modelId=$modelId runtime=${Platform.isAndroid ? 'android_ffi' : 'process_cli'}');
        RuntimeEventLog.instance.emit('[MODEL_COMPATIBLE] modelId=$modelId compatible=true');

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
          RuntimeEventLog.instance.emit('[VALIDATION_FAILURE] reason=ffi_binding_failed detail=${e.message}');

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
          RuntimeEventLog.instance.emit('[INFERENCE_ERROR] session=${request.sessionId} reason=cancelled');

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
          RuntimeEventLog.instance.emit('[INFERENCE_ERROR] session=${request.sessionId} reason=process_exit_code exitCode=$exitCode');

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
        RuntimeEventLog.instance.emit('[MODEL_READY] modelId=$modelId');
        RuntimeEventLog.instance.emit('[VALIDATION_SUCCESS] modelId=$modelId');

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
    // 1. Controlla prima i set statici di base delle piattaforme
    final baseAllowed =
        _isDesktopPlatform()
           ? _desktopValidatedModelIds
            : _mobileValidatedModelIds;

    if (baseAllowed.contains(modelId)) {
      return true;
    }

    // 2. Integrazione dinamica: Controlla se il modelId è presente in uno dei set di template dinamici
    return LocalInferenceModelIds.llama3ChatTemplateModels.contains(modelId) ||
        LocalInferenceModelIds.qwenChatTemplateModels.contains(modelId) ||
        LocalInferenceModelIds.gemmaChatTemplateModels.contains(modelId) ||
        LocalInferenceModelIds.phi3ChatTemplateModels.contains(modelId); // <- Sblocca l'ammissione dinamica di Phi-3.5
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
    final metadata = SamplingMetadata.fromPrompt(prompt);
    final cleanedPrompt = metadata.stripFrom(prompt);
    final effectiveTemperature = metadata.temperature ?? request.temperature;
    final effectiveTopP = metadata.topP ?? request.topP;
    final effectiveRepeatPenalty = metadata.repeatPenalty ?? request.repeatPenalty;

    return <String>[
      '-m',
      request.modelPath!,
      '-p',
      cleanedPrompt,
      '-n',
      request.maxTokens.toString(),
      '--temp',
      effectiveTemperature.toString(),
      '--top-p',
      effectiveTopP.toString(),
      '--top-k',
      LlamaNativeDefaults.topK.toString(),
      '--repeat-penalty',
      effectiveRepeatPenalty.toString(),
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
