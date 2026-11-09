import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_model_orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/stream_text_accumulator.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_lifecycle_policy.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/tool_interceptor_transformer.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/core/tools/web_search_tool.dart';
import 'package:flutter/foundation.dart';

class InferenceService {
  static const _logTag = 'INFERENCE';
  static const int _maxRetryCount = 1;
  static const int _maxChunksPerRequest = 4096;

  static const String _searchNoticePrefix = 'search:';

  bool _runtimeLookupInProgress = false;
  String? _lastCompletedAssistantLocalModelId;
  final LocalSessionModelAffinity _localAffinity = LocalSessionModelAffinity();
  final Future<ResourceSample?> Function() _sampleResources;

  InferenceService({
    required Future<AiModel?> Function() loadSelectedModel,
    required Future<AiRuntimeMode> Function() loadRuntimeMode,
    Future<List<AiModel>> Function()? loadAvailableLocalModels,
    Future<LocalModelSelectionMode> Function()? loadLocalModelSelectionMode,
    required LocalRuntimeProvider runtimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
    required RuntimeSessionManager sessionManager,
    Future<ResourceSample?> Function()? sampleResources,
    Tool? webSearchTool,
  })  : _loadSelectedModel = loadSelectedModel,
        _loadRuntimeMode = loadRuntimeMode,
        _loadAvailableLocalModels = loadAvailableLocalModels,
        _loadLocalModelSelectionMode = loadLocalModelSelectionMode,
        _runtimeProvider = runtimeProvider,
        _cloudRuntimeProvider = cloudRuntimeProvider,
        _sessionManager = sessionManager,
        _sampleResources = sampleResources ?? ResourceMonitor.instance.sample,
        _webSearchTool = webSearchTool;

  final Future<AiModel?> Function() _loadSelectedModel;
  final Future<AiRuntimeMode> Function() _loadRuntimeMode;
  final Future<List<AiModel>> Function()? _loadAvailableLocalModels;
  final Future<LocalModelSelectionMode> Function()? _loadLocalModelSelectionMode;
  final LocalRuntimeProvider _runtimeProvider;
  final CloudRuntimeProvider _cloudRuntimeProvider;
  final RuntimeSessionManager _sessionManager;
  final Tool? _webSearchTool;

  void cancel(String sessionId) {
    _log('cancel requested session=$sessionId');
    _sessionManager.cancel(sessionId);
  }

  TokenStream stream(InferenceRequest request) async* {
    final now = DateTime.now();
    // Minute precision avoids defeating cloud response caching on every call.
    // A new minute produces a fresh cache identity for relative-time queries.
    final localTime = DateTime(
      now.year, now.month, now.day, now.hour, now.minute,
    ).toIso8601String();
    final utcOffset = now.timeZoneOffset;
    final sign = utcOffset.isNegative ? '-' : '+';
    final offset = utcOffset.abs();
    final offsetText = '$sign${offset.inHours.toString().padLeft(2, '0')}:${(offset.inMinutes % 60).toString().padLeft(2, '0')}';
    final temporalContext =
        'Device system time (local): $localTime; UTC offset: $offsetText; '
        'timezone label: ${now.timeZoneName}. '
        'For current date/time, answer directly using this device clock '
        '(not independently verified). Do not invent a location. '
        'Verify changing external facts with current sources.';
    final priorSystemPrompt = request.systemPrompt?.trim();
    final expandedSystemPrompt =
        priorSystemPrompt == null || priorSystemPrompt.isEmpty
            ? temporalContext
            : '$priorSystemPrompt\n\n$temporalContext';
    // App-owned temporal context must be disclosed as an exact additional
    // system slice before any consent-controlled Cloud transport.
    // If a decorator changed system text without provenance, drop evidence
    // rather than allowing a forged classification or breaking normal Local.
    var trustedEvidence = request.trustedCloudSourceEvidence;
    if (trustedEvidence != null) {
      try {
        trustedEvidence = trustedEvidence.withTrustedRuntimeSystemAppend(
          previousSystemPrompt: priorSystemPrompt ?? '',
          appendedSystemPrompt: expandedSystemPrompt,
          trustedSuffix: temporalContext,
        );
      } catch (_) {
        trustedEvidence = null;
      }
    }
    final isolatedRequest = request.copyWith(
      systemPrompt: expandedSystemPrompt,
      trustedCloudSourceEvidence: trustedEvidence,
      discardTrustedCloudSourceEvidence:
          request.trustedCloudSourceEvidence != null && trustedEvidence == null,
    );
    _log(
      '[SYSTEM_TIME_CONTEXT] session=${isolatedRequest.sessionId} '
      'injected=true utc_offset=$offsetText source=device_clock',
    );

    _log('[INFERENCE_BEGIN] session=${isolatedRequest.sessionId}');
    _log(
      '[FORENSIC_INFERENCE_SERVICE_ENTRY] '
      'session=${isolatedRequest.sessionId} '
      'prompt_chars=${isolatedRequest.prompt.length} '
      'provider=${_runtimeProvider.runtimeType}',
    );
    _log('[ORCHESTRATOR_BEGIN] session=${isolatedRequest.sessionId}');
    _log(
      '[RUNTIME_PATH] '
      'stream_start session=${isolatedRequest.sessionId} '
      'provider=${_runtimeProvider.runtimeType}',
    );

    final promptHash = _promptHash(isolatedRequest);

    _log(
      'prompt creation '
      'session=${isolatedRequest.sessionId} '
      'prompt_hash=$promptHash '
      'prompt_chars=${isolatedRequest.prompt.length} '
      'context_turns=${isolatedRequest.context.length} '
      'offline=${isolatedRequest.isOffline}',
    );

    _log(
      '[RUNTIME_LOOKUP] '
      'session=${isolatedRequest.sessionId} '
      'stage=runtime_mode_load',
    );

    if (_runtimeLookupInProgress) {
      _log(
        '[RUNTIME_INIT_RECURSION] '
        'session=${isolatedRequest.sessionId} '
        'scope=inference_service.runtime_lookup',
      );
    }

    _runtimeLookupInProgress = true;

    final session =
        _sessionManager.startSession(isolatedRequest.sessionId);

    _log(
      '[INFERENCE_SESSION_CREATED] '
      'session=${isolatedRequest.sessionId}',
    );

    try {
      final runtimeMode = await _loadRuntimeMode();

      _log(
        '[INFERENCE_RUNTIME_SELECTED] '
        'session=${isolatedRequest.sessionId} '
        'runtime=${runtimeMode.name}',
      );

      _log(
        '[RUNTIME_LOOKUP] '
        'session=${isolatedRequest.sessionId} '
        'mode=${runtimeMode.name} '
        'provider=${_runtimeProvider.runtimeType}',
      );

      _log(
        '[RUNTIME_PATH] '
        'routing session=${isolatedRequest.sessionId} '
        'mode=${runtimeMode.name} '
        'provider=${_runtimeProvider.runtimeType} '
        'prompt_hash=$promptHash',
      );

      /*
       * IMPORTANT:
       *
       * An explicit modelId belongs to the caller's inference boundary.
       *
       * The Assistant normally sends requests without an explicit modelId,
       * therefore its existing selected-model behaviour is preserved.
       *
       * The Workshop sends its own modelId.
       * That request must never silently fall back to the Assistant's
       * currently selected model.
       */
      var selectedModel = await _resolveModelForRequest(isolatedRequest);
      var trackLocalAutoAffinity = false;
      List<AiModel> autoLocalModels = const <AiModel>[];

      // AUTO is only allowed at the ordinary Assistant boundary. Explicit
      // Workshop model identities remain immutable, including in HYBRID.
      if (runtimeMode != AiRuntimeMode.cloud &&
          isolatedRequest.modelId == null &&
          isolatedRequest.modelPath == null &&
          _loadAvailableLocalModels != null &&
          _loadLocalModelSelectionMode != null) {
        final selectionMode = await _loadLocalModelSelectionMode();
        if (selectionMode == LocalModelSelectionMode.automatic) {
          try {
            final models = await _loadAvailableLocalModels();
            autoLocalModels = models;
            ResourceSample? resources;
            final android = !kIsWeb &&
                defaultTargetPlatform == TargetPlatform.android;
            if (android) {
              try {
                resources = await _sampleResources();
              } catch (_) {
                // Missing telemetry is unknown, never interpreted as safe.
              }
            }
            // A completed model owns affinity only inside its own chat.
            // HYBRID may successfully deliver a Cloud fallback, so its
            // completion must not be treated as LOCAL resident evidence.
            final affinity = runtimeMode == AiRuntimeMode.local
                ? _localAffinity.get(isolatedRequest.sessionId)
                : null;
            final decision = const LocalModelOrchestrator().decide(
              request: isolatedRequest,
              availableModels: models,
              preferredModel: selectedModel,
              supportsModel: _runtimeProvider.supportsModel,
              resources: resources,
              isAndroid: android,
              lastCompletedModelId: affinity?.modelId,
              successfulTurnsSinceSwitch:
                  affinity?.successfulTurnsSinceSwitch ?? 99,
            );
            selectedModel = decision.model;
            trackLocalAutoAffinity =
                runtimeMode == AiRuntimeMode.local && selectedModel != null;
            _log(
              '[LOCAL_AUTO_ROUTE] session=${isolatedRequest.sessionId} '
              'installed=${models.length} selected=${selectedModel?.id ?? 'none'} '
              'task=${decision.task.name} '
              'ram_pressure=${resources?.pressure ?? 'unknown'}',
            );
            _log(
              '[LOCAL_AFFINITY] previous=${affinity?.modelId ?? 'none'} '
              'selected=${selectedModel?.id ?? 'none'} '
              'reason=${decision.reason.name} '
              'score_gain=${decision.scoreGain} '
              'turns_since_switch=${affinity?.successfulTurnsSinceSwitch ?? -1}',
            );
          } catch (error) {
            // Fail locally and explicitly; never infer that the manual model
            // is safe or authorize a Cloud dispatch after catalogue failure.
            selectedModel = null;
            _log('[LOCAL_AUTO_ROUTE] catalogue_error=$error');
          }
        } else if (runtimeMode == AiRuntimeMode.local) {
          // A deliberate return to MANUAL resets AUTO session stickiness.
          _localAffinity.reset();
        }
      }

      _log(
        '[INFERENCE_MODEL] '
        'session=${isolatedRequest.sessionId} '
        'requested_model=${isolatedRequest.modelId ?? 'none'} '
        'resolved_model=${selectedModel?.effectiveRuntimeModelId ?? 'none'}',
      );

      final localRequest =
          _buildLocalRequest(
        isolatedRequest,
        selectedModel,
      );

      _log(
        '[RUNTIME_LOOKUP] '
        'session=${isolatedRequest.sessionId} '
        'stage=provider_lookup '
        'local_provider=${_runtimeProvider.runtimeType} '
        'cloud_provider=${_cloudRuntimeProvider.runtimeType}',
      );

      _log(
        '[MODEL_LOAD] '
        'selection session=${isolatedRequest.sessionId} '
        'requested_model=${isolatedRequest.modelId ?? 'none'} '
        'selected_model=${selectedModel?.id ?? 'none'} '
        'local_runtime_connected=${localRequest != null} '
        'path=${selectedModel?.localPath ?? 'none'}',
      );

      _log(
        '[RUNTIME_LOOKUP] '
        'session=${isolatedRequest.sessionId} '
        'stage=request_construction '
        'local_request=${localRequest != null}',
      );

      _log(
        '[INFERENCE_STREAM_BEGIN] '
        'session=${isolatedRequest.sessionId} '
        'mode=${runtimeMode.name}',
      );

      _runtimeLookupInProgress = false;

      // Recovery is restricted to ordinary Assistant LOCAL AUTO. MANUAL,
      // Workshop explicit models and HYBRID keep their original routing.
      final TokenStream routedStream;
      if (trackLocalAutoAffinity &&
          localRequest != null &&
          selectedModel != null) {
        routedStream = _streamLocalAutoWithRecovery(
          cloudRequest: isolatedRequest,
          initialLocalRequest: localRequest,
          initialModel: selectedModel,
          availableModels: autoLocalModels,
          cancellationToken: session.cancellationToken,
          onFallbackSelected: (model) => selectedModel = model,
        );
      } else {
        routedStream = _streamWithRetryAndGuards(
          runtimeMode: runtimeMode,
          cloudRequest: isolatedRequest,
          localRequest: localRequest,
          cancellationToken: session.cancellationToken,
        );
      }
      await for (final chunk in routedStream) {
        if (trackLocalAutoAffinity &&
            chunk.isFinal &&
            chunk.terminalState == InferenceTerminalState.success &&
            !chunk.isError &&
            !session.cancellationToken.isCancelled &&
            localRequest != null &&
            selectedModel != null) {
          final actual = chunk.model;
          // Prefer the runtime-reported identity; do not promote an
          // unexpected model or an unverified Cloud fallback to affinity.
          if (actual == null ||
              actual == selectedModel!.effectiveRuntimeModelId ||
              actual == selectedModel!.id) {
            _localAffinity.recordSuccess(
                isolatedRequest.sessionId, selectedModel!.id);
            _log('[LOCAL_AFFINITY_COMMIT] model=${selectedModel!.id} '
                'turns_since_switch=${_localAffinity.get(isolatedRequest.sessionId)?.successfulTurnsSinceSwitch ?? -1}');
          }
        }
        yield chunk;
      }
    } catch (error, stackTrace) {
      _log(
        '[INFERENCE_ERROR] '
        'session=${isolatedRequest.sessionId} '
        'error=$error',
      );

      _log(
        '[ASYNC_FATAL] '
        'scope=inference_service.stream '
        'session=${isolatedRequest.sessionId} '
        'error=$error '
        'stack=$stackTrace',
      );

      yield InferenceResponse.error(
        'Inference service failed before runtime stream start: $error',
      );
    } finally {
      _runtimeLookupInProgress = false;

      _sessionManager.complete(session);

      _log(
        '[INFERENCE_FINISHED] '
        'session=${isolatedRequest.sessionId}',
      );

      _log(
        'async listener cleanup '
        'session=${isolatedRequest.sessionId}',
      );

      _log(
        'stream end '
        'session=${isolatedRequest.sessionId}',
      );

      _log(
        '[ORCHESTRATOR_END] '
        'session=${isolatedRequest.sessionId}',
      );
    }
  }

  Future<InferenceResponse> infer(
    InferenceRequest request,
  ) async {
    final buffer = StringBuffer();

    String model = InferenceConstants.localModelName;
    int tokens = 0;
    int timestamp =
        DateTime.now().millisecondsSinceEpoch;

    await for (final chunk in stream(request)) {
      _log(
        'infer chunk '
        'session=${request.sessionId} '
        'isFinal=${chunk.isFinal} '
        'isError=${chunk.isError} '
        'text_len=${chunk.text.length} '
        'tokens=${chunk.tokensGenerated} '
        'notice=${chunk.runtimeNotice != null}',
      );

      if (chunk.isError) {
        return InferenceResponse.error(
          chunk.errorMessage ?? 'Inference failed.',
        );
      }

      if (chunk.isFinal) {
        if (chunk.text.isNotEmpty) {
          final merged = mergeStreamedText(
            currentText: buffer.toString(),
            incomingText: chunk.text,
            isFinalChunk: true,
          );

          buffer
            ..clear()
            ..write(merged);
        }

        model = chunk.model ?? model;
        tokens = chunk.tokensGenerated;
        timestamp = chunk.timestamp;
      } else {
        final currentText = buffer.toString();
        final incomingText = chunk.text;

        if (incomingText.isNotEmpty &&
            currentText.isNotEmpty &&
            incomingText.startsWith(currentText)) {
          buffer
            ..clear()
            ..write(incomingText);
        } else {
          buffer.write(incomingText);
        }

        model = chunk.model ?? model;
      }
    }

    return InferenceResponse(
      text: buffer.toString(),
      model: model,
      tokensGenerated: tokens,
      timestamp: timestamp,
      isFinal: true,
    );
  }

  /// Resolves the model for the current inference request.
  ///
  /// Behaviour:
  ///
  /// 1. No explicit modelId:
  ///      preserve the existing Assistant behaviour.
  ///
  /// 2. Explicit modelId:
  ///      never silently substitute the currently selected Assistant model.
  ///
  /// This is the critical isolation boundary between Assistant and Workshop.
  ///
  /// At this stage the runtime still obtains concrete local model metadata
  /// from the existing selected-model loader. If the requested model is
  /// different, we deliberately return null for the local path instead of
  /// borrowing the Assistant's model.
  ///
  /// This means a Workshop model that is not yet installed/connected will
  /// fail explicitly rather than accidentally executing against the wrong
  /// model.
  Future<AiModel?> _resolveModelForRequest(
    InferenceRequest request,
  ) async {
    final requestedModelId =
        request.modelId?.trim();

    final selected =
        await _loadSelectedModelForLocalRuntime();

    if (requestedModelId == null ||
        requestedModelId.isEmpty) {
      return selected;
    }

    /*
     * An explicit modelPath makes the request self-describing enough to
     * preserve the caller's model identity even if the Assistant currently
     * has another model selected.
     *
     * Runtime validation still occurs through supportsModel().
     */
    if (request.modelPath != null &&
        request.modelPath!.trim().isNotEmpty) {
      if (selected != null &&
          selected.effectiveRuntimeModelId ==
              requestedModelId &&
          selected.localPath ==
              request.modelPath) {
        return selected;
      }

      if (selected != null) {
        _log(
          '[MODEL_ISOLATION] '
          'explicit_model=$requestedModelId '
          'assistant_selected=${selected.effectiveRuntimeModelId} '
          'action=reject_assistant_fallback',
        );
      } else {
        _log(
          '[MODEL_ISOLATION] '
          'explicit_model=$requestedModelId '
          'assistant_selected=none '
          'action=reject_assistant_fallback',
        );
      }

      /*
       * We intentionally do not manufacture an AiModel from an arbitrary
       * request here. The Workshop model must first be connected to the
       * application's model catalogue/storage boundary.
       */
      return null;
    }

    /*
     * The caller explicitly named a model but supplied no concrete local
     * path. Never reuse the Assistant's model.
     *
     * Cloud runtimes may still use request.modelId directly through
     * cloudRequest.
     */
    if (selected != null &&
        selected.effectiveRuntimeModelId !=
            requestedModelId) {
      _log(
        '[MODEL_ISOLATION] '
        'explicit_model=$requestedModelId '
        'assistant_selected=${selected.effectiveRuntimeModelId} '
        'action=reject_assistant_fallback',
      );
      return null;
    }

    return selected;
  }

  Future<AiModel?> _loadSelectedModelForLocalRuntime() async {
    AiModel? selected;

    try {
      selected =
          await _loadSelectedModel();
    } on Exception catch (e) {
      _log(
        '[VALIDATION] '
        'reason=model_selection_exception '
        'detail=$e – falling back to cloud',
      );

      return null;
    }

    if (selected == null) {
      _log(
        '[VALIDATION] '
        'reason=selected_null – no model has been chosen',
      );

      return null;
    }

    if (!selected.isDownloaded) {
      _log(
        '[VALIDATION] '
        'reason=model_not_downloaded '
        'modelId=${selected.id} '
        'displayName="${selected.displayName}"',
      );

      return null;
    }

    if (selected.localPath == null ||
        selected.localPath!.trim().isEmpty) {
      _log(
        '[VALIDATION] '
        'reason=localPath_missing '
        'modelId=${selected.id} '
        'localPath=${selected.localPath}',
      );

      return null;
    }

    if (selected.validationStatus ==
        ModelValidationStatus.invalidModel) {
      _log(
        '[VALIDATION] '
        'reason=invalidModel '
        'modelId=${selected.id} '
        'path=${selected.localPath}',
      );

      return null;
    }

    if (selected.validationStatus ==
        ModelValidationStatus.missingFile) {
      _log(
        '[VALIDATION] '
        'reason=missingFile '
        'modelId=${selected.id} '
        'path=${selected.localPath}',
      );

      return null;
    }

    if (selected.validationStatus ==
        ModelValidationStatus.notDownloaded) {
      _log(
        '[VALIDATION] '
        'reason=notDownloaded '
        'modelId=${selected.id}',
      );

      return null;
    }

    if (selected.validationStatus ==
        ModelValidationStatus.downloading) {
      _log(
        '[VALIDATION] '
        'reason=downloading – model transfer in progress '
        'modelId=${selected.id}',
      );

      return null;
    }

    if (!_runtimeProvider.supportsModel(selected)) {
      final effectiveId =
          selected.effectiveRuntimeModelId;
      final vs =
          selected.validationStatus;

      String rejectionReason;

      if (vs !=
          ModelValidationStatus.validatedOk) {
        rejectionReason =
            'unsupported_quantization_or_validation_status '
            '(validationStatus=$vs)';
      } else {
        rejectionReason =
            'runtime_provider_incompatibility – '
            'modelId="$effectiveId" '
            'not in validated set; possible unsupported architecture '
            'or tokenizer mismatch';
      }

      _log(
        '[VALIDATION] '
        'reason=$rejectionReason '
        'modelId=${selected.id} '
        'effectiveRuntimeModelId=$effectiveId '
        'validationStatus=$vs '
        'path=${selected.localPath}',
      );

      return null;
    }

    _log(
      '[VALIDATION] '
      'status=ok '
      'modelId=${selected.id} '
      'effectiveRuntimeModelId=${selected.effectiveRuntimeModelId} '
      'path=${selected.localPath}',
    );

    return selected;
  }

  InferenceRequest? _buildLocalRequest(
    InferenceRequest request,
    AiModel? selectedModel,
  ) {
    if (selectedModel == null) {
      _log(
        '[PRE_STREAM_LOCAL_REQUEST_SKIP] '
        'session=${request.sessionId} '
        'reason=selected_model_unavailable '
        'state=model_not_selected '
        'requested_model=${request.modelId ?? 'none'}',
      );

      return null;
    }

    if (selectedModel.localPath == null) {
      _log(
        '[PRE_STREAM_LOCAL_REQUEST_SKIP] '
        'session=${request.sessionId} '
        'reason=selected_model_missing_local_path '
        'modelId=${selectedModel.id}',
      );

      return null;
    }

    /*
     * An explicit modelId must match the concrete model selected for the
     * local runtime. This prevents the Assistant model from leaking into
     * Workshop inference.
     */
    final requestedModelId =
        request.modelId?.trim();

    final effectiveModelId =
        selectedModel.effectiveRuntimeModelId;

    if (requestedModelId != null &&
        requestedModelId.isNotEmpty &&
        requestedModelId != effectiveModelId) {
      _log(
        '[PRE_STREAM_LOCAL_REQUEST_SKIP] '
        'session=${request.sessionId} '
        'reason=explicit_model_mismatch '
        'requested_model=$requestedModelId '
        'resolved_model=$effectiveModelId',
      );

      return null;
    }

    _log(
      '[PRE_STREAM_LOCAL_REQUEST_READY] '
      'session=${request.sessionId} '
      'modelId=$effectiveModelId '
      'modelPath=${selectedModel.localPath}',
    );

    return request.copyWith(
      modelId: effectiveModelId,
      modelPath: selectedModel.localPath,
      maxTokens: request.preserveMaxTokens
          ? request.maxTokens
          : InferenceRequest.maxTokensForModel(effectiveModelId),
      temperature: request.preserveTemperature
          ? request.temperature
          : InferenceRequest.temperatureForModel(effectiveModelId),
    );
  }

  TokenStream _streamLocalInference({
    required InferenceRequest localRequest,
    required InferenceRequest cloudRequest,
    required CancellationToken cancellationToken,
    required bool allowCloudFallback,
  }) async* {
    var emittedLocalToken = false;
    var localChunkCount = 0;

    final runtimeState =
        _runtimeProvider.lifecycleRuntimeStateName;

    final activeTransitionId =
        _runtimeProvider.activeLifecycleTransitionId;

    final verificationState =
        _runtimeProvider.isRuntimeVerified(
      modelPath: localRequest.modelPath,
    );

    _log(
      '[PRE_INFERENCE_GATE] '
      'runtime_state=$runtimeState '
      'provider_hash=${_runtimeProvider.hashCode.toRadixString(16)} '
      'verification_state=$verificationState '
      'active_transition_id=$activeTransitionId',
    );

    _log(
      '[PRE_STREAM_INFERENCE] '
      'session=${localRequest.sessionId} '
      'runtime=${_runtimeProvider.runtimeType} '
      'modelId=${localRequest.modelId} '
      'modelPath=${localRequest.modelPath}',
    );

    String? detectedQuery;

    final firstGenerationToken =
        CancellationToken();

    cancellationToken.onCancel(
      firstGenerationToken.cancel,
    );

    final rawStream =
        _runtimeProvider.streamInference(
      request: localRequest,
      cancellationToken:
          firstGenerationToken,
    );

    /*
     * IMPORTANT:
     *
     * <search> is no longer parsed here with a local RegExp.
     *
     * ToolInterceptorTransformer is now the single interception boundary.
     *
     * Every model therefore enters the same protocol:
     *
     * LLM stream
     *     ↓
     * ToolInterceptorTransformer
     *     ↓
     * normal token OR search tool-call
     */
    final interceptedStream =
        rawStream.transform(
      ToolInterceptorTransformer(),
    );

    await for (final chunk
        in interceptedStream) {
      localChunkCount++;

      final runtimeNotice =
          chunk.runtimeNotice;

      if (runtimeNotice != null &&
          runtimeNotice.startsWith(
            _searchNoticePrefix,
          )) {
        final query = runtimeNotice
            .substring(
              _searchNoticePrefix.length,
            )
            .trim();

        if (query.isNotEmpty &&
            detectedQuery == null) {
          // A local PDF is untrusted evidence, not permission to use tools.
          // LOCAL mode alone allows optional web search for ordinary chat;
          // document requests explicitly prohibit all external tool calls.
          if (!localRequest.allowWebSearchTool) {
            _log(
              '[TOOL_EXECUTION_SKIPPED] '
              'tool=web_search '
              'session=${localRequest.sessionId} '
              'reason=local_document_tool_boundary',
            );
            firstGenerationToken.cancel();
            // Retain the original on-device PDF evidence and try once more,
            // without tools. A search-tag error must not prevent LOCAL from
            // answering a question it can resolve using the file itself.
            yield* _recoverLocalDocumentWithoutTools(
              request: localRequest,
              cancellationToken: cancellationToken,
            );
            return;
          }

          // For an explicitly requested document lookup, transmit only the
          // short, trusted original user query. The model's generated tag
          // can contain private PDF bytes or invented values; never use it.
          detectedQuery = localRequest.trustedDocumentWebQuery ?? query;

          if (localRequest.isOffline) {
            _log(
              '[TOOL_EXECUTION_SKIPPED] '
              'tool=web_search '
              'session=${localRequest.sessionId} '
              'reason=offline_hard_boundary',
            );

            yield InferenceResponse.notice(
              'Offline mode: web search was blocked. '
              'Continuing with local knowledge only.',
            );
          } else {
            _log(
              '[INTERCEPTOR] '
              'Detected internet search tool-call. '
              'Query: "$detectedQuery"',
            );

            yield InferenceResponse.notice(
              '\n\n'
              '🔍 *Searching the web for: '
              '"$detectedQuery"...*'
              '\n\n',
            );
          }

          firstGenerationToken.cancel();

          continue;
        }
      }

      _log(
        '[TOKEN_STREAM] '
        'local chunk '
        'session=${localRequest.sessionId} '
        'chunk=$localChunkCount '
        'isFinal=${chunk.isFinal} '
        'isError=${chunk.isError} '
        'text_len=${chunk.text.length} '
        'tokens=${chunk.tokensGenerated} '
        'notice=${chunk.runtimeNotice}',
      );

      if (chunk.isError &&
          _isStalledPreInferenceError(
            chunk.errorMessage,
          )) {
        cancellationToken.cancel();

        _log(
          '[INFERENCE_ERROR] '
          'session=${localRequest.sessionId} '
          'reason=stalled_pre_inference',
        );

        _log(
          '[TERMINAL_STATE] '
          'state=stalled_pre_inference '
          'session=${localRequest.sessionId} '
          'stage=local_stream_guard',
        );
      }

      if (chunk.isError &&
          allowCloudFallback &&
          !emittedLocalToken &&
          _cloudRuntimeProvider.canInfer) {
        _log(
          '[RUNTIME_PATH] '
          'fallback session=${localRequest.sessionId} '
          'from=local to=cloud '
          'reason=${chunk.errorMessage}',
        );

        yield InferenceResponse.notice(
          'Local runtime failed, switching to cloud runtime.',
        );

        yield*
            _cloudRuntimeProvider.streamInference(
          request: cloudRequest,
          cancellationToken:
              cancellationToken,
        );

        return;
      }

      if (!chunk.isError &&
          !chunk.isFinal &&
          chunk.text.isNotEmpty) {
        emittedLocalToken = true;
      }

      yield chunk;
    }

    if (detectedQuery != null &&
        detectedQuery.isNotEmpty) {
      if (localRequest.isOffline) {
        yield* _recoverOfflineSearchWithoutTools(
          localRequest: localRequest,
          cancellationToken: cancellationToken,
        );
        return;
      }

      try {
        final searchTool =
            _webSearchTool ?? WebSearchTool();

        _log(
          '[TOOL_EXECUTION_BEGIN] '
          'tool=web_search '
          'session=${localRequest.sessionId} '
          'query="$detectedQuery"',
        );

        final searchResult =
            await searchTool.execute(
          {'query': detectedQuery},
        );
        if (!searchResult.success) {
          throw StateError('Public Web search unavailable');
        }

        _log(
          '[INTERCEPTOR] '
          'Search completed successfully. '
          'Restarting local inference with the results.',
        );

        final enrichedPrompt =
            '${localRequest.prompt}\n\n'
            '[INTERNET SEARCH RESULTS]\n'
            '${searchResult.output}\n\n'
            'Use the information above to accurately complete '
            'the user\'s original request.';

        final updatedLocalRequest =
            localRequest.copyWith(
          sessionId:
              '${localRequest.sessionId}::search',
          prompt: enrichedPrompt,
          // Only the completed tool call may attest to evidence in the prompt.
          systemPrompt: [
            if (localRequest.systemPrompt?.trim().isNotEmpty ?? false)
              localRequest.systemPrompt!.trim(),
            '[INTERNET SEARCH RESULTS]\n'
                'A Web lookup has completed. Its results are supplied with the '
                'user request as untrusted evidence. Answer using that evidence; '
                'do not request another lookup.',
          ].join('\n\n'),
        );

        final continuationToken =
            CancellationToken();

        cancellationToken.onCancel(
          continuationToken.cancel,
        );

        _log(
          '[TOOL_EXECUTION_END] '
          'tool=web_search '
          'session=${localRequest.sessionId} '
          'status=success '
          'continuation_session='
          '${updatedLocalRequest.sessionId}',
        );

        yield*
            _runtimeProvider.streamInference(
          request: updatedLocalRequest,
          cancellationToken:
              continuationToken,
        );

        return;
      } catch (e) {
        _log(
          '[INTERCEPTOR_ERROR] '
          'code=WEB_SEARCH_RECOVERY_FAILED '
          'error=$e',
        );

        if (localRequest.trustedDocumentWebQuery != null) {
          yield InferenceResponse.notice(
            'Verifica online non disponibile: continuo con il PDF locale.',
          );
          yield* _recoverLocalDocumentWithoutTools(
            request: localRequest,
            cancellationToken: cancellationToken,
          );
          return;
        }

        yield InferenceResponse.error(
          'Unable to retrieve web data. See logs for details.',
        );
        return;
      }
    }

    _log(
      '[FINAL_RESPONSE] '
      'local stream end '
      'session=${localRequest.sessionId} '
      'emittedLocalToken=$emittedLocalToken '
      'chunks=$localChunkCount',
    );
  }

  TokenStream _recoverLocalDocumentWithoutTools({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    final retryToken = CancellationToken();
    cancellationToken.onCancel(retryToken.cancel);
    final retryRequest = request.copyWith(
      sessionId: '${request.sessionId}::document-no-tools',
      systemPrompt: '${request.systemPrompt ?? ''}\n'
          'Rispondi usando solo il documento già fornito. '
          'Non usare strumenti o tag di ricerca Web.',
      maxTokens: request.maxTokens > 256 ? 256 : request.maxTokens,
      preserveMaxTokens: true,
      allowWebSearchTool: false,
    );

    _log(
      '[DOCUMENT_TOOL_RECOVERY] '
      'session=${request.sessionId} mode=on_device_once_only',
    );

    final recovered = _runtimeProvider.streamInference(
      request: retryRequest,
      cancellationToken: retryToken,
    ).transform(ToolInterceptorTransformer());

    await for (final chunk in recovered) {
      final notice = chunk.runtimeNotice;
      if (notice != null && notice.startsWith(_searchNoticePrefix)) {
        retryToken.cancel();
        yield InferenceResponse.finalChunk(
          text: 'Il modello ha richiesto di nuovo una ricerca Web '
              'non autorizzata per questo PDF. Nessun dato è stato '
              'inviato online. La risposta locale non è disponibile.',
          tokensGenerated: 0,
          model: request.modelId ?? 'unknown',
          providerId: 'local_document_tool_blocked',
        );
        return;
      }
      yield chunk;
    }
  }

  TokenStream _recoverOfflineSearchWithoutTools({
    required InferenceRequest localRequest,
    required CancellationToken cancellationToken,
  }) async* {
    final recoveryToken = CancellationToken();
    cancellationToken.onCancel(recoveryToken.cancel);

    final sections = <String>[];
    final baseSystemPrompt = localRequest.systemPrompt?.trim();
    if (baseSystemPrompt != null && baseSystemPrompt.isNotEmpty) {
      sections.add(baseSystemPrompt);
    }

    final originalPrompt = localRequest.prompt.trim();
    if (originalPrompt.isNotEmpty) {
      sections.add('Original user request:\n$originalPrompt');
    }

    sections.add(
      '[OFFLINE HARD BOUNDARY]\n'
      'This turn is explicitly offline. External tools and network lookups are '
      'forbidden. Answer the original user request only from local/project '
      'knowledge. If a fact may have changed, say that it cannot be verified '
      'live while offline. Do not emit tool-call tags.',
    );

    final recoveryRequest = localRequest.copyWith(
      sessionId: '${localRequest.sessionId}::offline-search-recovery',
      prompt:
          'Answer the original user request now using local/project knowledge '
          'only. Do not request or invoke any external tool.',
      systemPrompt: sections.join('\n\n'),
    );

    _log(
      '[OFFLINE_SEARCH_RECOVERY] '
      'session=${localRequest.sessionId} '
      'action=local_retry_no_tools',
    );

    final recoveryStream = _runtimeProvider
        .streamInference(
          request: recoveryRequest,
          cancellationToken: recoveryToken,
        )
        .transform(ToolInterceptorTransformer());

    await for (final chunk in recoveryStream) {
      final notice = chunk.runtimeNotice;
      if (notice != null && notice.startsWith(_searchNoticePrefix)) {
        _log(
          '[TOOL_EXECUTION_SKIPPED] '
          'tool=web_search '
          'session=${localRequest.sessionId} '
          'reason=offline_recovery_repeated_tool_call',
        );
        recoveryToken.cancel();

        yield InferenceResponse.finalChunk(
          text:
              'Live information cannot be verified while offline. '
              'The model attempted to request an external lookup again, '
              'so the request was stopped without network access.',
          tokensGenerated: 0,
          model: localRequest.modelId ?? 'unknown',
        );
        return;
      }

      yield chunk;
    }
  }


  /// One pre-first-content LOCAL AUTO alternative, never a Cloud dispatch.
  /// The failed runtime is drained before a different GGUF is considered.
  TokenStream _streamLocalAutoWithRecovery({
    required InferenceRequest cloudRequest,
    required InferenceRequest initialLocalRequest,
    required AiModel initialModel,
    required List<AiModel> availableModels,
    required CancellationToken cancellationToken,
    required void Function(AiModel) onFallbackSelected,
  }) async* {
    InferenceResponse? originalFailure;
    var emittedContent = false;
    var completedNormally = false;
    var emittedNotice = false;
    await for (final chunk in _streamWithRetryAndGuards(
      runtimeMode: AiRuntimeMode.local,
      cloudRequest: cloudRequest,
      localRequest: initialLocalRequest,
      cancellationToken: cancellationToken,
    )) {
      // Even a whitespace chunk is already an emitted token: never replay
      // the same turn through a second model after any model output.
      if (chunk.text.isNotEmpty) emittedContent = true;
      if (chunk.runtimeNotice?.trim().isNotEmpty == true) {
        // A notice may be an externally observable tool action. Never rerun
        // an already started tool sequence through a second model.
        emittedNotice = true;
      }
      if (chunk.isFinal &&
          !chunk.isError &&
          chunk.terminalState == InferenceTerminalState.success) {
        completedNormally = true;
      }
      if (chunk.isError && !emittedContent && !completedNormally) {
        originalFailure ??= chunk;
        continue;
      }
      yield chunk;
    }

    if (originalFailure == null || completedNormally) return;
    if (emittedContent ||
        emittedNotice ||
        cancellationToken.isCancelled ||
        !_isRecoverableLocalStartupFailure(originalFailure)) {
      _log('[LOCAL_AUTO_RECOVERY] result=skipped reason=unsafe_or_ineligible');
      yield originalFailure;
      return;
    }

    final android = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android;
    ResourceSample? resources;
    if (android) {
      try {
        resources = await _sampleResources();
      } catch (_) {
        // Unknown RAM telemetry cannot authorize a second GGUF.
      }
      if (resources == null || resources.pressured ||
          cancellationToken.isCancelled) {
        _log('[LOCAL_AUTO_RECOVERY] result=skipped reason=ram_or_cancel');
        yield originalFailure;
        return;
      }
    }

    final runtimeState =
        _runtimeProvider.lifecycleRuntimeStateName.toLowerCase();
    if (runtimeState.contains('unload') ||
        runtimeState.contains('load') ||
        runtimeState.contains('dispos') ||
        runtimeState.contains('poison') ||
        runtimeState.contains('unsafe') ||
        runtimeState == 'tokenizing' ||
        runtimeState == 'inferencing' ||
        runtimeState == 'streaming' ||
        runtimeState == 'stalled' ||
        runtimeState == 'timedOut') {
      _log('[LOCAL_AUTO_RECOVERY] result=skipped reason=runtime_transition');
      yield originalFailure;
      return;
    }

    // Only already validated models, excluding failed aliases of the same
    // path. The normal router enforces device RAM and runtime compatibility.
    final alternatives = availableModels.where((model) =>
        model.id != initialModel.id &&
        model.localPath != initialModel.localPath);
    final alternative = const LocalModelOrchestrator().decide(
      request: cloudRequest,
      availableModels: alternatives,
      preferredModel: null,
      supportsModel: _runtimeProvider.supportsModel,
      resources: resources,
      isAndroid: android,
    ).model;
    if (alternative == null || cancellationToken.isCancelled) {
      _log('[LOCAL_AUTO_RECOVERY] result=skipped reason=no_safe_alternative');
      yield originalFailure;
      return;
    }

    final retryRequest = _buildLocalRequest(cloudRequest, alternative);
    if (retryRequest == null) {
      yield originalFailure;
      return;
    }
    onFallbackSelected(alternative);
    _log('[LOCAL_AUTO_RECOVERY] result=retry phase=pre_first_token '
        'from=${initialModel.id} to=${alternative.id}');

    var secondTerminal = false;
    await for (final chunk in _streamWithRetryAndGuards(
      runtimeMode: AiRuntimeMode.local,
      cloudRequest: cloudRequest,
      localRequest: retryRequest,
      cancellationToken: cancellationToken,
    )) {
      if (chunk.isFinal) secondTerminal = true;
      yield chunk;
    }
    if (!secondTerminal && !cancellationToken.isCancelled) {
      yield InferenceResponse.error('Local recovery ended without a response.');
    }
  }

  /// Startup failures only: permission, policy, cancellation and OOM are not
  /// routing signals and never authorize an implicit model switch.
  bool _isRecoverableLocalStartupFailure(InferenceResponse failure) {
    if (!failure.isError || failure.errorCode != null) return false;
    if (failure.terminalState != InferenceTerminalState.failed &&
        failure.terminalState != InferenceTerminalState.modelUnavailable) {
      return false;
    }
    final reason = (failure.errorMessage ?? '').toLowerCase();
    if (reason.isEmpty ||
        <String>[
          'memory', 'oom', 'low_memory', 'insufficiente', 'out of',
          'cancel', 'permission', 'denied', 'consent', 'unauthoriz',
          'forbidden', 'tool', 'invalid', 'unsafe', 'shutdown',
          'context length', 'timeout', 'quota', 'safety',
        ].any(reason.contains)) {
      return false;
    }
    return <String>[
      'model unavailable',
      'model file not found',
      // Real Android FFI startup errors are serialized by
      // RuntimeStageException as AI_RUNTIME_ERROR|stage=session_create|...
      'stage=session_create|message=session create failed.',
      'stage=session_create|message=failed to create runtime session.',
      'native session creation failed',
      'native session inactive after create',
      'failed to load model',
      'model load failed',
      'gguf load failed',
      'failed to initialize',
      'initialization failed',
      'runtime unavailable',
      'runtime startup failed',
      'backend failed to start',
      'process exited',
    ].any(reason.contains);
  }

  TokenStream _streamWithRetryAndGuards({
    required AiRuntimeMode runtimeMode,
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
  }) async* {
    for (var attempt = 1;
        attempt <= _maxRetryCount + 1;
        attempt++) {
      var emittedContent = false;
      var shouldRetry = false;
      var retryReason = '';
      var firstTokenLogged = false;
      var streamedChunkCount = 0;
      var terminalChunkSeen = false;
      final attemptClock = Stopwatch()..start();
      int? firstContentMs;

      final routedStream = _routeInference(
        runtimeMode: runtimeMode,
        cloudRequest: cloudRequest,
        localRequest: localRequest,
        cancellationToken: cancellationToken,
      );

      await for (final chunk
          in _guardInferenceStream(
        stream: routedStream,
        sessionId: cloudRequest.sessionId,
        cancellationToken: cancellationToken,
        attempt: attempt,
        runtimeMode: runtimeMode,
      )) {
        // Once a terminal response has been delivered to the consumer, keep
        // draining the upstream stream until its natural close. Returning from
        // this await-for immediately would cancel the upstream subscription.
        // On Android that cancellation propagates to the cached native llama
        // session and can poison the very next same-model inference.
        if (terminalChunkSeen) {
          continue;
        }

        if (chunk.runtimeNotice != null &&
            chunk.runtimeNotice!
                .trim()
                .isNotEmpty) {
          _log(
            '[TOKEN_STREAM] '
            'notice '
            'session=${cloudRequest.sessionId} '
            'notice="${chunk.runtimeNotice}"',
          );

          yield chunk;
          continue;
        }

        if (chunk.text.trim().isNotEmpty) {
          emittedContent = true;
          firstContentMs ??= attemptClock.elapsedMilliseconds;

          if (!firstTokenLogged) {
            firstTokenLogged = true;

            _log(
              '[INFERENCE_FIRST_TOKEN] '
              'session=${cloudRequest.sessionId} '
              'attempt=$attempt',
            );
          }
        }

        if (!chunk.isFinal && !chunk.isError && chunk.text.isNotEmpty) {
          streamedChunkCount++;
        }

        if (chunk.isError &&
            runtimeMode !=
                AiRuntimeMode.local &&
            attempt <= _maxRetryCount &&
            !emittedContent &&
            _isRetryableError(
              chunk.errorMessage,
            )) {
          shouldRetry = true;

          retryReason =
              chunk.errorMessage ??
                  'transient runtime failure';

          _log(
            '[RUNTIME_PATH] '
            'retry '
            'session=${cloudRequest.sessionId} '
            'attempt=$attempt '
            'reason="$retryReason"',
          );

          continue;
        }

        if (chunk.isFinal &&
            !chunk.isError) {
          _log(
            '[INFERENCE_LAST_TOKEN] '
            'session=${cloudRequest.sessionId} '
            'attempt=$attempt',
          );

          _log(
            '[STREAM_TOKEN_COUNT] '
            'session=${cloudRequest.sessionId} '
            'attempt=$attempt '
            'tokens=${chunk.tokensGenerated} chunks=$streamedChunkCount',
          );
        }

        if (chunk.isFinal) {
          final model = chunk.model ??
              (runtimeMode == AiRuntimeMode.local ? localRequest?.modelId : null) ??
              'unknown';
          final safeModel = RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(model)
              ? model : 'unknown';
          _log('[INFERENCE_TIMING] model=$safeModel mode=${runtimeMode.name} '
              'attempt=$attempt first_content_ms=${firstContentMs ?? -1} '
              'total_ms=${attemptClock.elapsedMilliseconds} '
              'reported_tokens=${chunk.tokensGenerated} text_chunks=$streamedChunkCount '
              'outcome=${chunk.isError ? 'error' : 'success'}');
          // Completion is the only reliable boundary for asserting which
          // model actually answered. This intentionally excludes explicit
          // Workshop model identities and any failed LOCAL attempt.
          if (!chunk.isError &&
              chunk.terminalState == InferenceTerminalState.success &&
              runtimeMode == AiRuntimeMode.local &&
              cloudRequest.modelId == null &&
              cloudRequest.modelPath == null &&
              safeModel != 'unknown') {
            final previous = _lastCompletedAssistantLocalModelId;
            final changed = previous != null && previous != safeModel;
            _log('[LOCAL_MODEL_USED] model=$safeModel '
                'previous=${previous ?? 'none'} changed=$changed');
            _lastCompletedAssistantLocalModelId = safeModel;
          }
        }

        _log(
          '[FINAL_RESPONSE] '
          'session=${cloudRequest.sessionId} '
          'attempt=$attempt '
          'isFinal=${chunk.isFinal} '
          'isError=${chunk.isError} '
          'text_len=${chunk.text.length}',
        );

        yield chunk;

        if (chunk.isFinal) {
          terminalChunkSeen = true;
        }
      }

      if (terminalChunkSeen) {
        return;
      }

      if (!shouldRetry ||
          cancellationToken.isCancelled) {
        return;
      }

      yield InferenceResponse.notice(
        'Transient runtime issue detected, retrying once.',
      );
    }
  }

  TokenStream _routeInference({
    required AiRuntimeMode runtimeMode,
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
  }) {
    switch (runtimeMode) {
      case AiRuntimeMode.local:
        _log(
          '[RUNTIME_PATH] '
          'mode=local '
          'session=${cloudRequest.sessionId} '
          'local_request=${localRequest != null}',
        );

        _log(
          '[RUNTIME_PROVIDER_BRANCH] '
          'provider=${_runtimeProvider.runtimeType} '
          'runtime_mode=${runtimeMode.name} '
          'branch=local '
          'local_request_available=${localRequest != null}',
        );

        if (localRequest != null) {
          _log(
            '[PRE_STREAM_FORWARD] '
            'session=${cloudRequest.sessionId} '
            'boundary=inference_service.route '
            'mode=${runtimeMode.name} '
            'target=inference_service._streamLocalInference',
          );

          return _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: cloudRequest,
            cancellationToken:
                cancellationToken,
            allowCloudFallback: false,
          );
        }

        _log(
          '[PRE_STREAM_BYPASS] '
          'session=${cloudRequest.sessionId} '
          'boundary=inference_service.route '
          'mode=${runtimeMode.name} '
          'reason=local_request_unavailable '
          'target=inference_service._streamLocalInference_not_invoked',
        );

        return Stream<InferenceResponse>.value(
          InferenceResponse.error(
            'Local AI mode requires the requested Workshop model to be '
            'installed, validated and connected to the local runtime.',
          ),
        );

      case AiRuntimeMode.cloud:
        _log(
          '[RUNTIME_PATH] '
          'mode=cloud '
          'session=${cloudRequest.sessionId}',
        );

        _log(
          '[RUNTIME_PROVIDER_BRANCH] '
          'provider=${_cloudRuntimeProvider.runtimeType} '
          'runtime_mode=${runtimeMode.name} '
          'branch=cloud '
          'local_request_available=false',
        );

        _log(
          '[PRE_STREAM_FORWARD] '
          'session=${cloudRequest.sessionId} '
          'boundary=inference_service.route '
          'mode=${runtimeMode.name} '
          'target=cloud_runtime_provider.streamInference',
        );

        return _streamAutomaticOrchestration(
          cloudRequest: cloudRequest,
          localRequest: localRequest,
          cancellationToken:
              cancellationToken,
          forceCloudPrimary: true,
        );

      case AiRuntimeMode.hybrid:
        _log(
          '[RUNTIME_PATH] '
          'mode=hybrid '
          'session=${cloudRequest.sessionId}',
        );

        _log(
          '[RUNTIME_PROVIDER_BRANCH] '
          'provider=${_runtimeProvider.runtimeType}|'
          '${_cloudRuntimeProvider.runtimeType} '
          'runtime_mode=${runtimeMode.name} '
          'branch=hybrid '
          'local_request_available='
          '${localRequest != null}',
        );

        _log(
          '[PRE_STREAM_FORWARD] '
          'session=${cloudRequest.sessionId} '
          'boundary=inference_service.route '
          'mode=${runtimeMode.name} '
          'target=automatic_orchestration '
          'local_request_available='
          '${localRequest != null}',
        );

        return _streamAutomaticOrchestration(
          cloudRequest: cloudRequest,
          localRequest: localRequest,
          cancellationToken:
              cancellationToken,
        );
    }
  }

  TokenStream _guardInferenceStream({
    required TokenStream stream,
    required String sessionId,
    required CancellationToken cancellationToken,
    required int attempt,
    required AiRuntimeMode runtimeMode,
  }) async* {
    final lifecycleClock = InferenceLifecycleClock();
    // Hybrid may route LOCAL first or fall back to LOCAL inside the same
    // stream. Only cloud-only mode can safely use the shorter generic idle
    // guard without racing Android's provider-owned first-token deadline.
    final streamIdleTimeout = InferenceLifecyclePolicy.outerIdleTimeoutFor(
      cloudOnly: runtimeMode == AiRuntimeMode.cloud,
    );
    var chunkCount = 0;

    await for (final chunk
        in stream.timeout(
      streamIdleTimeout,
      onTimeout: (sink) {
        cancellationToken.cancel();

        _log(
          '[TERMINAL_STATE] state=timedOut '
          'reason=${InferenceLifecycleTerminalReason.outerStreamIdleTimeout.wireName} '
          'session=$sessionId attempt=$attempt '
          'idle_ms=${lifecycleClock.sinceLastProgress.inMilliseconds}',
        );

        sink.add(
          InferenceResponse.error(
            'Inference stream timed out waiting for progress.',
            state: InferenceTerminalState.timeout,
          ),
        );

        sink.close();
      },
    )) {
      chunkCount++;

      lifecycleClock.markProgress(
        content: chunk.runtimeNotice == null &&
            !chunk.isError &&
            chunk.text.trim().isNotEmpty,
      );

      if (chunkCount >
          _maxChunksPerRequest) {
        cancellationToken.cancel();

        _log(
          'hard stop protection '
          'session=$sessionId '
          'attempt=$attempt '
          'max_chunks=$_maxChunksPerRequest '
          'reason=${InferenceLifecycleTerminalReason.streamChunkLimit.wireName}',
        );

        yield InferenceResponse.error(
          'Inference stopped after exceeding safe stream chunk limit.',
        );

        return;
      }

      // No absolute wall-clock deadline is applied after stream progress.
      // Productive generation is bounded by provider max tokens, explicit
      // cancellation, resource/repetition guards and no-progress watchdogs.

      yield chunk;
    }
  }

  bool _isRetryableError(
    String? errorMessage,
  ) {
    final normalized =
        (errorMessage ?? '').toLowerCase();

    return normalized.contains('timeout') ||
        normalized.contains('timed out') ||
        normalized.contains('stalled') ||
        normalized.contains('tempor') ||
        normalized.contains('network');
  }

  bool _isStalledPreInferenceError(
    String? errorMessage,
  ) {
    final normalized =
        (errorMessage ?? '').toLowerCase();

    return normalized.contains(
          'stage=stalled_pre_inference',
        ) ||
        normalized.contains(
          'stalled_pre_inference',
        );
  }

  String _promptHash(
    InferenceRequest request,
  ) {
    return secureForensicHash(
      [
        request.sessionId,
        request.prompt.trim(),
        request.systemPrompt?.trim() ?? '',
        request.context
            .map(
              (turn) =>
                  '${turn.role.name}:${turn.content}',
            )
            .join('\n'),
      ].join('\u0000'),
    );
  }

  TokenStream _streamAutomaticOrchestration({
    required InferenceRequest cloudRequest,
    required InferenceRequest? localRequest,
    required CancellationToken cancellationToken,
    bool forceCloudPrimary = false,
  }) async* {
    if (cloudRequest.isOffline) {
      if (localRequest != null) {
        _log(
          'fallback routing '
          'session=${cloudRequest.sessionId} '
          'from=cloud to=local '
          'reason=offline',
        );

        _log(
          '[PRE_STREAM_FORWARD] '
          'session=${cloudRequest.sessionId} '
          'boundary=inference_service.automatic_orchestration '
          'reason=offline '
          'target=inference_service._streamLocalInference',
        );

        yield* _streamLocalInference(
          localRequest: localRequest,
          cloudRequest: cloudRequest,
          cancellationToken:
              cancellationToken,
          allowCloudFallback: false,
        );

        return;
      }

      _log(
        '[PRE_STREAM_BYPASS] '
        'session=${cloudRequest.sessionId} '
        'boundary=inference_service.automatic_orchestration '
        'reason=offline_without_local_request '
        'target=inference_service._streamLocalInference_not_invoked',
      );

      yield InferenceResponse.error(
        'Network is unavailable and no local model is ready for use.',
      );

      return;
    }

    final shouldPreferCloud =
        forceCloudPrimary ||
        _cloudRuntimeProvider
            .shouldPreferCloudFor(
      cloudRequest,
    );

    if (!shouldPreferCloud &&
        localRequest != null) {
      _log(
        'routing '
        'session=${cloudRequest.sessionId} '
        'mode=local-first '
        'cloudPreferred=$shouldPreferCloud',
      );

      _log(
        '[PRE_STREAM_FORWARD] '
        'session=${cloudRequest.sessionId} '
        'boundary=inference_service.automatic_orchestration '
        'reason=hybrid_local_first '
        'target=inference_service._streamLocalInference',
      );

      yield* _streamLocalInference(
        localRequest: localRequest,
        cloudRequest: cloudRequest,
        cancellationToken:
            cancellationToken,
        allowCloudFallback: true,
      );

      return;
    }

    _log(
      '[PRE_STREAM_FORWARD] '
      'session=${cloudRequest.sessionId} '
      'boundary=inference_service.automatic_orchestration '
      'reason=${forceCloudPrimary ? 'force_cloud_primary' : 'cloud_preferred'} '
      'target=cloud_runtime_provider.streamInference '
      'local_request_available=${localRequest != null}',
    );

    await for (final chunk
        in _cloudRuntimeProvider
            .streamInference(
      request: cloudRequest,
      cancellationToken:
          cancellationToken,
    )) {
      if (chunk.runtimeNotice != null &&
          chunk.runtimeNotice!
              .trim()
              .isNotEmpty) {
        yield chunk;
        continue;
      }

      if (chunk.isError) {
        if (localRequest != null &&
            _cloudRuntimeProvider
                .shouldFallBackToLocal(
          chunk.errorMessage,
        )) {
          _log(
            'fallback routing '
            'session=${cloudRequest.sessionId} '
            'from=cloud to=local '
            'reason=${chunk.errorMessage}',
          );

          _log(
            '[PRE_STREAM_FORWARD] '
            'session=${cloudRequest.sessionId} '
            'boundary=inference_service.automatic_orchestration '
            'reason=cloud_error_fallback '
            'target=inference_service._streamLocalInference',
          );

          final notice =
              _cloudRuntimeProvider
                  .consumeRuntimeNotice();

          if (notice != null) {
            yield InferenceResponse.notice(
              notice,
            );
          }

          yield* _streamLocalInference(
            localRequest: localRequest,
            cloudRequest: cloudRequest,
            cancellationToken:
                cancellationToken,
            allowCloudFallback: false,
          );

          return;
        }
      }

      yield chunk;
    }
  }

  static void _log(
    String message,
  ) {
    debugPrint(
      '[$_logTag] $message',
    );

    RuntimeEventLog.instance.emit(
      message,
    );
  }
}
