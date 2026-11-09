import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'dart:async';

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_provider_adapter.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_consent_denied.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_source_evidence.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  const validModel = AiModel(
    id: 'gemma_2b',
    displayName: 'Gemma 2B',
    fileName: 'gemma.gguf',
    downloadUrl: 'https://example.com/model.gguf',
    version: '1.0.0',
    sizeBytes: 123,
    description: 'Test model',
    isDownloaded: true,
    localPath: '/tmp/gemma.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  InferenceService buildService({
    required AiRuntimeMode mode,
    AiModel? selectedModel,
    List<AiModel>? availableModels,
    LocalModelSelectionMode localSelectionMode = LocalModelSelectionMode.manual,
    required FakeLocalRuntimeProvider localRuntimeProvider,
    required CloudRuntimeProvider cloudRuntimeProvider,
    Future<ResourceSample?> Function()? sampleResources,
    Tool? webSearchTool,
  }) {
    return InferenceService(
      loadSelectedModel: () async => selectedModel,
      loadRuntimeMode: () async => mode,
      loadAvailableLocalModels: () async => availableModels ?? <AiModel>[],
      loadLocalModelSelectionMode: () async => localSelectionMode,
      runtimeProvider: localRuntimeProvider,
      cloudRuntimeProvider: cloudRuntimeProvider,
      sessionManager: RuntimeSessionManager(),
      sampleResources: sampleResources,
      webSearchTool: webSearchTool,
    );
  }

  /// Builds a [CloudRuntimeProvider] suitable for testing.
  ///
  /// [configured] controls whether the provider reports itself as available.
  /// [automaticUseAllowed] is explicit so routing tests do not depend on the
  /// process-wide spending preference singleton. Tests that exercise the
  /// fail-closed policy can set it to [false].
  /// When [configured] is false the cloud provider appears unconfigured and
  /// [InferenceService] falls back to local mode or reports an error.
  CloudRuntimeProvider buildCloudProvider({
    bool configured = true,
    bool automaticUseAllowed = true,
    Future<AiResponse> Function(String provider, AiRequest request)? sendQuery,
  }) {
    return CloudRuntimeProvider(
      sendQuery: sendQuery ??
          (_, __) async => AiResponse(
                text: 'Cloud response',
                model: 'gpt-4o',
                tokensUsed: 8,
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => configured,
      providerDisplayName: ([providerName]) => 'OpenAI',
      automaticUseAllowed: (_) => automaticUseAllowed,
    );
  }


  test('LOCAL AUTO pre-token load failure tries one compatible GGUF, '
      'preserving approved context, single final and no Cloud', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    RuntimeEventLog.instance.clear();
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
      sizeBytes: 1700000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    final seen = <InferenceRequest>[];
    var cloudCalls = 0;
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          seen.add(request);
          if (seen.length == 1) {
            yield InferenceResponse.error('Failed to load model');
          } else {
            yield InferenceResponse.finalChunk(
              text: 'Risposta unica', tokensGenerated: 2,
              model: request.modelId,
            );
          }
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(
        configured: true,
        automaticUseAllowed: true,
        sendQuery: (provider, request) async {
          cloudCalls++;
          throw StateError('LOCAL must not contact Cloud');
        },
      ),
    );
    const evidence = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'Kader è alto.'),
    ];
    final replies = await service.stream(const InferenceRequest(
      sessionId: 'memory-chat',
      prompt: 'Scrivi codice Dart',
      context: evidence,
      systemPrompt: 'Confirmed memory: Kader è alto.',
    )).toList();
    expect(seen.map((x) => x.modelId).toList(), [
      qwen.effectiveRuntimeModelId, phi.effectiveRuntimeModelId,
    ]);
    expect(seen[1].sessionId, seen[0].sessionId);
    expect(seen[1].systemPrompt, seen[0].systemPrompt);
    expect(seen[1].context, seen[0].context);
    expect(cloudCalls, 0);
    expect(replies.where((x) => x.isError), isEmpty);
    expect(replies.where((x) => x.isFinal), hasLength(1));
    expect(replies.last.model, phi.effectiveRuntimeModelId);
    final affinityCommits = RuntimeEventLog.instance.entries
        .map((x) => x.message)
        .where((x) => x.startsWith('[LOCAL_AFFINITY_COMMIT]'))
        .toList();
    expect(affinityCommits, hasLength(1));
    expect(affinityCommits.single, contains('model=${phi.id}'));
  });


  test('Android FFI session_create startup failure can recover pre-token',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    final seen = <String?>[];
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          seen.add(request.modelId);
          if (seen.length == 1) {
            yield InferenceResponse.error(
              'AI_RUNTIME_ERROR|stage=session_create|'
              'message=Session create failed.|'
              'details=StateError: Native session creation failed: backend error',
            );
          } else {
            yield InferenceResponse.finalChunk(
              text: 'Ok', tokensGenerated: 1, model: request.modelId,
            );
          }
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'native-recovery', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(seen, [
      qwen.effectiveRuntimeModelId, phi.effectiveRuntimeModelId,
    ]);
    expect(output.where((x) => x.isError), isEmpty);
    expect(output.where((x) => x.isFinal), hasLength(1));
  });

  test('Android FFI memory-related session_create failure never switches',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    var calls = 0;
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (_, __) async* {
          calls++;
          yield InferenceResponse.error(
            'AI_RUNTIME_ERROR|stage=session_create|'
            'message=Session create failed.|'
            'details=Memoria insufficiente: out of memory.',
          );
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'native-memory-error', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(calls, 1);
    expect(output.where((x) => x.isError), hasLength(1));
  });

  test('Android high pressure after startup failure blocks a second GGUF',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
      sizeBytes: 1700000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    var samples = 0;
    var loads = 0;
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      sampleResources: () async {
        samples++;
        return ResourceSample(<Object?, Object?>{
          'totalBytes': 8 * 1024 * 1024 * 1024,
          'availableBytes': samples == 1
              ? 2 * 1024 * 1024 * 1024
              : 400 * 1024 * 1024,
          'thresholdBytes': 256 * 1024 * 1024,
        });
      },
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (_, __) async* {
          loads++;
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'high-ram', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(samples, 2);
    expect(loads, 1);
    expect(output.where((x) => x.isError), hasLength(1));
  });

  test('LOCAL AUTO cancellation after failure never loads fallback',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    var loads = 0;
    late InferenceService service;
    service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          loads++;
          service.cancel(request.sessionId);
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'cancel-retry', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(loads, 1);
    expect(output.where((x) => x.isError), hasLength(1));
  });


  test('LOCAL AUTO does not replay a tool notice on model fallback', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    var loads = 0;
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (_, __) async* {
          loads++;
          yield InferenceResponse.notice('Local tool request started');
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'notice-guard', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(loads, 1);
    expect(output.where((x) => x.runtimeNotice != null), hasLength(1));
    expect(output.where((x) => x.isError), hasLength(1));
  });

  test('LOCAL AUTO never switches after the first visible text', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    final seen = <String?>[];
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          seen.add(request.modelId);
          yield InferenceResponse.token(text: 'Prima parte');
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final replies = await service.stream(const InferenceRequest(
      sessionId: 'no-duplicate', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(seen, [qwen.effectiveRuntimeModelId]);
    expect(replies.where((x) => x.text == 'Prima parte'), hasLength(1));
    expect(replies.where((x) => x.isError), hasLength(1));
  });

  test('LOCAL AUTO treats whitespace output as first token and never replays',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    var loads = 0;
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (_, __) async* {
          loads++;
          yield InferenceResponse.token(text: ' ');
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final output = await service.stream(const InferenceRequest(
      sessionId: 'whitespace-first-token', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(loads, 1);
    expect(output.where((x) => x.text == ' '), hasLength(1));
    expect(output.where((x) => x.isError), hasLength(1));
  });

  test('LOCAL AUTO two startup failures emit one terminal error, '
      'with no third model', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    final seen = <String?>[];
    final service = buildService(
      mode: AiRuntimeMode.local, selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          seen.add(request.modelId);
          yield InferenceResponse.error(
            seen.length == 1 ? 'Failed to load model' : 'Initialization failed');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final replies = await service.stream(const InferenceRequest(
      sessionId: 'both-fail', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(seen, [
      qwen.effectiveRuntimeModelId, phi.effectiveRuntimeModelId,
    ]);
    expect(replies.where((x) => x.isError && x.isFinal), hasLength(1));
    expect(replies.last.errorMessage, 'Initialization failed');
  });

  test('LOCAL MANUAL and explicit Workshop model never auto-recover',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
    );
    for (final explicit in [false, true]) {
      var requests = 0;
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: phi,
        availableModels: [phi, qwen],
        localSelectionMode: explicit
            ? LocalModelSelectionMode.automatic
            : LocalModelSelectionMode.manual,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (_, __) async* {
            requests++;
            yield InferenceResponse.error('Failed to load model');
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(configured: false),
      );
      final replies = await service.stream(InferenceRequest(
        sessionId: explicit ? 'workshop' : 'manual',
        prompt: 'Scrivi codice Dart',
        modelId: explicit ? phi.effectiveRuntimeModelId : null,
        modelPath: explicit ? phi.localPath : null,
      )).toList();
      expect(requests, 1);
      expect(replies.where((x) => x.isError), hasLength(1));
    }
  });

  test('Android critical LOW_MEMORY stops LOCAL AUTO second load', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
      sizeBytes: 1700000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    var loads = 0;
    final critical = ResourceSample(<Object?, Object?>{
      'totalBytes': 8 * 1024 * 1024 * 1024,
      'lowMemory': true,
      'availableBytes': 128 * 1024 * 1024,
      'thresholdBytes': 256 * 1024 * 1024,
    });
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi, availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      sampleResources: () async => critical,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (_, __) async* {
          loads++;
          yield InferenceResponse.error('Failed to load model');
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    final replies = await service.stream(const InferenceRequest(
      sessionId: 'critical-ram', prompt: 'Scrivi codice Dart',
    )).toList();
    expect(loads, 1);
    expect(replies.where((x) => x.isError), hasLength(1));
  });

  test('LOCAL AUTO retains the last completed model per conversation',
      () async {
    RuntimeEventLog.instance.clear();
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
      sizeBytes: 2200000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    final seen = <String, List<String?>>{};
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        seen.putIfAbsent(request.sessionId, () => []).add(request.modelId);
        yield InferenceResponse.finalChunk(
          text: 'OK', tokensGenerated: 1, model: request.modelId,
        );
      }),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    for (final request in [
      const InferenceRequest(sessionId: 'chat-a',
          prompt: 'Scrivi codice Dart'),
      const InferenceRequest(sessionId: 'chat-a',
          prompt: 'Chi è alto?'),
      const InferenceRequest(sessionId: 'chat-b',
          prompt: 'Ciao, come stai?'),
      const InferenceRequest(sessionId: 'chat-a',
          prompt: 'Chi pratica sport?'),
    ]) {
      await service.stream(request).drain<void>();
    }
    expect(seen['chat-a'], [
      qwen.effectiveRuntimeModelId,
      qwen.effectiveRuntimeModelId,
      qwen.effectiveRuntimeModelId,
    ]);
    expect(seen['chat-b'], [phi.effectiveRuntimeModelId]);
    final commits = RuntimeEventLog.instance.entries
        .map((entry) => entry.message)
        .where((entry) => entry.startsWith('[LOCAL_AFFINITY_COMMIT]'))
        .toList();
    expect(commits, hasLength(4));
    expect(commits.first, contains('model=${qwen.id}'));
  });

  test('non-recoverable LOCAL AUTO error does not pin an unsuccessful LLM',
      () async {
    RuntimeEventLog.instance.clear();
    final phi = validModel.copyWith(
      id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
      sizeBytes: 2200000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct', localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    final seen = <String?>[];
    var first = true;
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        seen.add(request.modelId);
        if (first) {
          first = false;
          yield InferenceResponse.error('Permission denied');
        } else {
          yield InferenceResponse.finalChunk(
            text: 'OK', tokensGenerated: 1, model: request.modelId,
          );
        }
      }),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    await service.stream(const InferenceRequest(
        sessionId: 'same-chat', prompt: 'Scrivi codice Dart')).drain<void>();
    await service.stream(const InferenceRequest(
        sessionId: 'same-chat', prompt: 'Ciao, come stai?')).drain<void>();
    expect(seen, [qwen.effectiveRuntimeModelId, phi.effectiveRuntimeModelId]);
    final committed = RuntimeEventLog.instance.entries
        .map((entry) => entry.message)
        .where((entry) => entry.startsWith('[LOCAL_AFFINITY_COMMIT]'))
        .toList();
    expect(committed, hasLength(1));
    expect(committed.single, contains('model=${phi.id}'));
  });

  test('LOCAL AUTO cross-model handoff preserves confirmed memory, corrections '
      'and current language without leaking another conversation', () async {
    // Flutter unit tests default to Android, regardless of host runner OS.
    // Use the desktop threshold to force a legitimate Phi → Qwen switch;
    // the separate router suite verifies stricter Android anti-switch logic.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final phi = validModel.copyWith(
      id: 'phi3_5_mini',
      localPath: '/tmp/phi.gguf',
      sizeBytes: 2200000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct',
      localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    const evidence = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'Jerome è alto.'),
      ChatTurn(role: ChatRole.assistant, content: 'Ricevuto.'),
      ChatTurn(role: ChatRole.user, content: 'Mika pratica sport.'),
      ChatTurn(role: ChatRole.assistant, content: 'Ricevuto.'),
      ChatTurn(role: ChatRole.user,
          content: 'Correzione: non Jerome, ma Kader è alto.'),
      ChatTurn(role: ChatRole.assistant,
          content: 'Ho capito: Kader è alto e Mika pratica sport.'),
    ];
    const approved = 'Memoria confermata: Mika pratica sport. '
        'Kader è alto. Jerome non è alto. '
        'Lingua preferita per questa chat: italiano.';
    final seen = <InferenceRequest>[];
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider: FakeLocalRuntimeProvider(
        streamBuilder: (request, _) async* {
          seen.add(request);
          yield InferenceResponse.finalChunk(
            text: 'Risposta di prova.',
            tokensGenerated: 4,
            model: request.modelId,
          );
        },
      ),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );

    await service.stream(const InferenceRequest(
      sessionId: 'chat-relazioni',
      prompt: 'Chi è alto?',
      systemPrompt: approved,
      context: evidence,
    )).drain<void>();
    await service.stream(const InferenceRequest(
      sessionId: 'chat-relazioni',
      prompt: 'Scrivi codice Dart per i fatti relazionali.',
      systemPrompt: approved,
      context: evidence,
    )).drain<void>();
    await service.stream(const InferenceRequest(
      sessionId: 'chat-separata',
      prompt: 'Ciao, come va?',
      systemPrompt: 'Solo contesto della nuova conversazione.',
    )).drain<void>();

    expect(seen, hasLength(3));
    expect(seen[0].modelId, phi.effectiveRuntimeModelId);
    expect(seen[1].modelId, qwen.effectiveRuntimeModelId);
    for (final request in seen.take(2)) {
      expect(request.context, evidence);
      expect(request.systemPrompt, contains(approved));
      expect(request.systemPrompt, contains('Jerome non è alto'));
      expect(request.systemPrompt, contains('Lingua preferita'));
    }
    expect(seen[2].context, isEmpty);
    expect(seen[2].systemPrompt, contains('Solo contesto'));
    expect(seen[2].systemPrompt, isNot(contains('Kader')));
    expect(seen[2].systemPrompt, isNot(contains('Mika')));
  });

  test('LOCAL AUTO changes model for coding but preserves dialogue context',
      () async {
    final phi = validModel.copyWith(
      id: 'phi3_5_mini',
      localPath: '/tmp/phi.gguf',
      sizeBytes: 2200000000,
    );
    final qwen = validModel.copyWith(
      id: 'qwen2_5_3b_instruct',
      localPath: '/tmp/qwen.gguf',
      sizeBytes: 1800000000,
    );
    final seen = <InferenceRequest>[];
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        seen.add(request);
        yield InferenceResponse.finalChunk(text: 'ok', tokensGenerated: 1);
      }),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    const memoryContext = [
      ChatTurn(role: ChatRole.user, content: 'Jerome è un mio collega'),
      ChatTurn(role: ChatRole.assistant, content: 'Ricevuto'),
    ];
    await service.stream(const InferenceRequest(
      sessionId: 'local-auto-context',
      prompt: 'Scrivi codice Dart per una funzione',
      context: memoryContext,
      systemPrompt: 'Approved memory: Jerome is a colleague.',
    )).drain<void>();
    expect(seen, hasLength(1));
    expect(seen.single.modelId, qwen.effectiveRuntimeModelId);
    expect(seen.single.context, memoryContext);
    expect(seen.single.systemPrompt,
        contains('Approved memory: Jerome is a colleague.'));
  });

  test('LOCAL manual selection remains authoritative even for coding',
      () async {
    final phi = validModel.copyWith(id: 'phi3_5_mini');
    final qwen = validModel.copyWith(id: 'qwen2_5_3b_instruct');
    InferenceRequest? seen;
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.manual,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        seen = request;
        yield InferenceResponse.finalChunk(text: 'ok', tokensGenerated: 1);
      }),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    await service.stream(const InferenceRequest(
      sessionId: 'manual-local', prompt: 'Scrivi codice Dart',
    )).drain<void>();
    expect(seen?.modelId, phi.effectiveRuntimeModelId);
  });

  test('LOCAL AUTO never overrides an explicit Workshop model ID',
      () async {
    final phi = validModel.copyWith(id: 'phi3_5_mini');
    final qwen = validModel.copyWith(id: 'qwen2_5_3b_instruct');
    InferenceRequest? seen;
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: phi,
      availableModels: [phi, qwen],
      localSelectionMode: LocalModelSelectionMode.automatic,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        seen = request;
        yield InferenceResponse.finalChunk(text: 'ok', tokensGenerated: 1);
      }),
      cloudRuntimeProvider: buildCloudProvider(configured: false),
    );
    await service.stream(const InferenceRequest(
      sessionId: 'workshop-local', prompt: 'Scrivi codice Dart',
      modelId: 'phi3_5_mini',
    )).drain<void>();
    expect(seen?.modelId, 'phi3_5_mini');
  });

  test('device clock context reaches local inference and preserves instructions',
      () async {
    InferenceRequest? captured;
    final service = buildService(
      mode: AiRuntimeMode.local,
      selectedModel: validModel,
      localRuntimeProvider:
          FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
        captured = request;
        yield InferenceResponse.finalChunk(text: 'ok', tokensGenerated: 1);
      }),
      cloudRuntimeProvider: buildCloudProvider(),
    );
    await service.stream(const InferenceRequest(
      sessionId: 'clock-local',
      prompt: 'Che giorno e oggi?',
      systemPrompt: 'Keep the answer concise.',
    )).drain<void>();
    expect(captured, isNotNull);
    expect(captured!.systemPrompt, contains('Keep the answer concise.'));
    expect(captured!.systemPrompt,
        contains('Keep the answer concise.\n\nDevice system time'));
    expect(captured!.systemPrompt, contains('Device system time (local):'));
    expect(captured!.systemPrompt, contains('UTC offset:'));
    expect(captured!.systemPrompt,
        contains('answer directly using this device clock'));
    expect(captured!.systemPrompt,
        contains('not independently verified'));
    expect(captured!.systemPrompt,
        contains('Verify changing external facts with current sources'));
    expect(captured!.prompt, 'Che giorno e oggi?');
  });

  test('Cloud runtime preserves source-backed evidence of device time',
      () async {
    InferenceRequest? observed;
    var legacySends = 0;
    final cloud = CloudRuntimeProvider(
      consentGated: true,
      sendQuery: (_, __) async {
        legacySends++;
        throw StateError('Legacy transport must not run');
      },
      consentGatedSend: (source, projected, token) async {
        observed = source;
        expect(projected.systemPrompt, contains('Device system time'));
        expect(token.isCancelled, isFalse);
        throw const HybridCloudConsentDenied();
      },
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'OpenAI',
      automaticUseAllowed: (_) => true,
      modelForProvider: (_) => 'gpt-test',
    );
    final service = buildService(
      mode: AiRuntimeMode.cloud,
      selectedModel: validModel,
      localRuntimeProvider: FakeLocalRuntimeProvider(),
      cloudRuntimeProvider: cloud,
    );
    final evidence = HybridCloudRuntimeSourceEvidence(
      sessionId: 'clock-evidence',
      originalQuestion: 'Hello',
      baseSystemPrompt: 'You are Aivexus',
      originalHistory: const <AiMessage>[],
    );
    final input = InferenceRequest(
      sessionId: 'clock-evidence', prompt: 'Hello',
      systemPrompt: 'You are Aivexus',
      routeDirective: InferenceRouteDirective.cloudOnly,
      trustedCloudSourceEvidence: evidence,
    );
    await service.stream(input).drain<void>();
    expect(observed, isNotNull);
    final updated = observed!.trustedCloudSourceEvidence;
    expect(updated, isNotNull);
    expect(updated!.runtimeSystemPromptSuffix,
        contains('Device system time (local):'));
    expect(observed!.systemPrompt, updated.expectedSystemPrompt);
    expect(legacySends, 0);

    // When another layer injects context before time augmentation, its
    // fabricated provenance is not preserved into the Cloud boundary.
    observed = null;
    await service.stream(input.copyWith(
      systemPrompt: 'You are Aivexus\nUNKNOWN WEB TOOL RESULTS',
    )).drain<void>();
    expect(observed, isNotNull);
    expect(observed!.trustedCloudSourceEvidence, isNull);
    expect(legacySends, 0);
  });

  group('InferenceService routing', () {
    test(
        'Workshop settings survive gateway, role adapter and local model resolution',
        () async {
      final seen = <InferenceRequest>[];
      final model = validModel.copyWith(id: 'qwen2_5_3b_instruct');
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: model,
        localRuntimeProvider:
            FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
          seen.add(request);
          yield InferenceResponse.finalChunk(text: '{}', tokensGenerated: 1);
        }),
        cloudRuntimeProvider: buildCloudProvider(),
      );
      final gateway = WorkshopInferenceGateway(
          provider: WorkshopInferenceProviderAdapter(
        inferenceService: service,
        modelId: model.id,
      ));
      await gateway
          .stream(
              prompt: 'plan',
              sessionId: 'plan',
              maxTokens: 768,
              temperature: 0.2)
          .drain<void>();
      await gateway
          .stream(
              prompt: 'compact plan',
              sessionId: 'retry',
              maxTokens: 640,
              temperature: 0.1)
          .drain<void>();
      await gateway
          .streamWithIdentity(
              prompt: 'compact Engineer',
              sessionId: 'resume',
              maxTokens: 512,
              temperature: 0.15,
              requestId: 'request',
              projectId: 'project',
              taskId: 'task',
              executionId: 'execution',
              attemptId: 'attempt',
              checkpointId: 'checkpoint')
          .drain<void>();
      await gateway
          .stream(prompt: 'default preflight', sessionId: 'default')
          .drain<void>();
      await gateway
          .stream(prompt: 'only budget', sessionId: 'budget', maxTokens: 320)
          .drain<void>();
      await gateway
          .stream(
              prompt: 'only temperature',
              sessionId: 'temperature',
              temperature: 0.05)
          .drain<void>();
      await service
          .stream(const InferenceRequest(
              prompt: 'ordinary chat', sessionId: 'chat'))
          .drain<void>();
      expect(seen.map((r) => r.maxTokens), [768, 640, 512, 768, 320, 768, 768]);
      expect(seen.map((r) => r.temperature),
          [0.2, 0.1, 0.15, 0.5, 0.5, 0.05, 0.5]);
      expect(
          seen
              .take(3)
              .every((r) => r.preserveMaxTokens && r.preserveTemperature),
          isTrue);
      expect(seen.map((r) => r.modelId).toSet(), {model.id});
      expect(seen[2].requestId, 'request');
      expect(seen[2].projectId, 'project');
      expect(seen[2].taskId, 'task');
      expect(seen[2].executionId, 'execution');
      expect(seen[2].attemptId, 'attempt');
      expect(seen[2].checkpointId, 'checkpoint');
    });

    test('re-reads selected model for each request in the same chat', () async {
      RuntimeEventLog.instance.clear();
      var selected =
          validModel.copyWith(id: 'phi3_5_mini', localPath: '/tmp/phi.gguf');
      final seenModels = <String?>[];
      final seenPaths = <String?>[];
      final service = InferenceService(
        loadSelectedModel: () async => selected,
        loadRuntimeMode: () async => AiRuntimeMode.local,
        runtimeProvider:
            FakeLocalRuntimeProvider(streamBuilder: (request, _) async* {
          seenModels.add(request.modelId);
          seenPaths.add(request.modelPath);
          yield InferenceResponse.finalChunk(
              text: 'OK', tokensGenerated: 1, model: request.modelId);
        }),
        cloudRuntimeProvider: buildCloudProvider(),
        sessionManager: RuntimeSessionManager(),
      );
      await service
          .stream(const InferenceRequest(prompt: 'Ciao', sessionId: 'switch'))
          .toList();
      selected = validModel.copyWith(
          id: 'nemotron3_nano_4b', localPath: '/tmp/nemotron.gguf');
      await service
          .stream(const InferenceRequest(prompt: 'Ciao', sessionId: 'switch'))
          .toList();
      expect(seenModels, ['phi3_5_mini', 'nemotron3_nano_4b']);
      expect(seenPaths, ['/tmp/phi.gguf', '/tmp/nemotron.gguf']);
      final completed = RuntimeEventLog.instance.entries
          .map((entry) => entry.message)
          .where((message) => message.startsWith('[LOCAL_MODEL_USED]'))
          .toList(growable: false);
      expect(completed, hasLength(2));
      expect(completed[0], contains('model=phi3_5_mini previous=none changed=false'));
      expect(completed[1],
          contains('model=nemotron3_nano_4b previous=phi3_5_mini changed=true'));
    });

    test('local error timing retains the requested model', () async {
      RuntimeEventLog.instance.clear();
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(responses: [
          InferenceResponse.error('Memory pressure'),
        ]),
        cloudRuntimeProvider: buildCloudProvider(),
      );
      final responses = await service
          .stream(const InferenceRequest(prompt: 'Ciao', sessionId: 'memory'))
          .toList();
      expect(responses.last.isError, isTrue);
      final timing = RuntimeEventLog.instance.entries
          .map((e) => e.message)
          .where((e) => e.startsWith('[INFERENCE_TIMING]'))
          .single;
      expect(timing, contains('model=gemma_2b mode=local'));
      expect(timing, contains('first_content_ms=-1'));
      expect(timing, contains('outcome=error'));
    });

    test('local mode returns streamed final response', () async {
      RuntimeEventLog.instance.clear();
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.token(text: 'Hello ', model: 'gemma_2b'),
            InferenceResponse.token(text: 'world', model: 'gemma_2b'),
            InferenceResponse.finalChunk(
              text: 'Hello world',
              tokensGenerated: 2,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 'local-stream', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Hello world');
      expect(response.model, 'gemma_2b');
      expect(response.tokensGenerated, 2);
      final events =
          RuntimeEventLog.instance.entries.map((e) => e.message).toList();
      expect(
          events,
          contains(
              '[STREAM_TOKEN_COUNT] session=local-stream attempt=1 tokens=2 chunks=2'));
      expect(
          events.where((e) => e.startsWith('[INFERENCE_TIMING]')).single,
          allOf(contains('model=gemma_2b mode=local'),
              contains('reported_tokens=2 text_chunks=2 outcome=success')));
    });

    test(
        'terminal local response drains upstream without cancelling cached runtime',
        () async {
      final localProvider = _FinalThenNaturalCloseProvider();
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: localProvider,
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final first = await service
          .stream(
            const InferenceRequest(
              sessionId: 'handoff-role-a',
              prompt: 'first role',
            ),
          )
          .toList();

      final second = await service
          .stream(
            const InferenceRequest(
              sessionId: 'handoff-role-b',
              prompt: 'second role',
            ),
          )
          .toList();

      expect(first.last.isFinal, isTrue);
      expect(first.last.text, 'response-1');
      expect(second.last.isFinal, isTrue);
      expect(second.last.text, 'response-2');
      expect(localProvider.prematureCancelCalls, 0);
      expect(localProvider.requests, 2);
    });

    test('cancel propagates to local runtime stream', () async {
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (_, cancellationToken) async* {
            yield InferenceResponse.token(text: 'partial', model: 'gemma_2b');
            while (!cancellationToken.isCancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
              yield InferenceResponse.token(text: '.', model: 'gemma_2b');
            }
            yield InferenceResponse.error('Inference cancelled.');
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final streamFuture = service
          .stream(
              const InferenceRequest(sessionId: 'cancel-s1', prompt: 'hello'))
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      service.cancel('cancel-s1');

      final chunks = await streamFuture;
      expect(chunks.any((chunk) => chunk.isError), true);
    });

    test('starting a new inference cancels the previous session', () async {
      final startedSessions = <String>[];
      final cancelledSessions = <String>[];
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            startedSessions.add(request.sessionId);
            cancellationToken.onCancel(() {
              cancelledSessions.add(request.sessionId);
            });
            yield InferenceResponse.token(
              text: request.sessionId,
              model: 'gemma_2b',
            );
            while (!cancellationToken.isCancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
            yield InferenceResponse.error('Inference cancelled.');
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final firstStream = service
          .stream(
              const InferenceRequest(sessionId: 'session-1', prompt: 'hello'))
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final secondChunks = await service
          .stream(
              const InferenceRequest(sessionId: 'session-2', prompt: 'world'))
          .take(1)
          .toList();
      final firstChunks = await firstStream;

      expect(startedSessions, <String>['session-1', 'session-2']);
      expect(cancelledSessions, <String>['session-1']);
      expect(firstChunks.any((chunk) => chunk.isError), true);
      expect(secondChunks.single.text, 'session-2');
    });

    test('returns error when cloud mode has no API key and no local model',
        () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: null,
        localRuntimeProvider: FakeLocalRuntimeProvider(),
        cloudRuntimeProvider: buildCloudProvider(configured: false),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's1', prompt: 'hello'),
      );

      expect(response.isError, true);
      // When no provider is available and no local model exists, the
      // CloudRuntimeProvider emits its "fully local" notice as an error and
      // InferenceService propagates it.
      expect(response.errorMessage, CloudRuntimeProvider.fullyLocalNotice);
    });

    test('fails explicitly when cloud mode is selected without API key',
        () async {
      var cloudCalls = 0;
      var localCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (_, __) async* {
            localCalls += 1;
            yield InferenceResponse.finalChunk(
              text: 'Local response',
              tokensGenerated: 4,
              model: 'gemma_2b',
            );
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(
          configured: false,
          sendQuery: (_, __) async {
            cloudCalls += 1;
            throw AssertionError('cloud should not be called');
          },
        ),
      );

      final chunks = await service
          .stream(const InferenceRequest(sessionId: 's2', prompt: 'hello'))
          .toList();
      final terminal = chunks.last;

      expect(terminal.isError, true);
      expect(
        terminal.terminalState,
        anyOf(
          InferenceTerminalState.modelUnavailable,
          InferenceTerminalState.failed,
        ),
      );
      expect(localCalls, 0);
      expect(cloudCalls, 0);
    });

    test('falls back to local when cloud authentication fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.cloud,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.finalChunk(
              text: 'Recovered locally',
              tokensGenerated: 6,
              model: 'gemma_2b',
            ),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(
          sendQuery: (_, __) async => throw const ServerFailure(
            'OpenAI API error 401: invalid_api_key',
          ),
        ),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's3', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Recovered locally');
      expect(response.model, 'gemma_2b');
    });

    test('hybrid mode falls back to cloud when local startup fails', () async {
      final service = buildService(
        mode: AiRuntimeMode.hybrid,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.error('Missing local model path.'),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's4', prompt: 'hello'),
      );

      expect(response.isError, false);
      expect(response.text, 'Cloud response');
      expect(response.model, 'gpt-4o');
    });

    test('hybrid mode does not auto-spend when Cloud policy blocks it',
        () async {
      var cloudCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.hybrid,
        selectedModel: validModel,
        localRuntimeProvider: FakeLocalRuntimeProvider(
          responses: <InferenceResponse>[
            InferenceResponse.error('Missing local model path.'),
          ],
        ),
        cloudRuntimeProvider: buildCloudProvider(
          automaticUseAllowed: false,
          sendQuery: (_, __) async {
            cloudCalls += 1;
            return AiResponse(
              text: 'should not run',
              model: 'gpt-4o',
              tokensUsed: 1,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            );
          },
        ),
      );

      final response = await service.infer(
        const InferenceRequest(sessionId: 's4-policy', prompt: 'hello'),
      );

      expect(response.isError, true);
      expect(cloudCalls, 0);
    });

    test('local search continuation uses a fresh cancellation token', () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: '''
Query: weather in rome
Top results:
1. Rome forecast
   URL: https://example.com/rome
   Snippet: Sunny.
''',
          success: true,
        ),
      );
      var streamInvocations = 0;
      final seenSessionIds = <String>[];
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: const AiModel(
          id: 'phi3_5_mini',
          displayName: 'Phi-3.5 Mini Instruct',
          fileName: 'phi3.gguf',
          downloadUrl: 'https://example.com/model.gguf',
          version: '1.0.0',
          sizeBytes: 123,
          description: 'Test model',
          isDownloaded: true,
          localPath: '/tmp/phi3.gguf',
          validationStatus: ModelValidationStatus.validatedOk,
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            streamInvocations += 1;
            seenSessionIds.add(request.sessionId);
            if (streamInvocations == 1) {
              expect(cancellationToken.isCancelled, isFalse);
              yield InferenceResponse.token(
                text: '<search>weather in rome</search>',
                model: 'phi3_5_mini',
              );
              return;
            }

            expect(cancellationToken.isCancelled, isFalse);
            expect(request.prompt, contains('[INTERNET SEARCH RESULTS]'));
            final composed = LocalPromptTemplates.compose(
              modelId: 'phi3_5_mini',
              prompt: request.prompt,
              systemPrompt: request.systemPrompt,
              emitDiagnostics: false,
            );
            expect(composed, contains('https://example.com/rome'));
            expect(composed, isNot(contains('<search>query</search>')));
            yield InferenceResponse.finalChunk(
              text: 'Rome weather is sunny.',
              tokensGenerated: 5,
              model: 'phi3_5_mini',
            );
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
        webSearchTool: searchTool,
      );

      final response = await service.infer(
        const InferenceRequest(
          sessionId: 'search-s1',
          prompt: 'What is the weather in Rome?',
        ),
      );

      expect(response.isError, false);
      expect(response.text, 'Rome weather is sunny.');
      expect(searchTool.calls, 1);
      expect(streamInvocations, 2);
      expect(seenSessionIds, <String>['search-s1', 'search-s1::search']);
    });

    test('PDF LOCAL rejects model web-search tag without using network or cloud',
        () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: 'This external result must never be used.',
          success: true,
        ),
      );
      var localCalls = 0;
      var cloudCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel.copyWith(
          id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            localCalls++;
            expect(request.allowWebSearchTool, isFalse);
            if (localCalls == 1) {
              yield InferenceResponse.token(
                text: '<search>Thé vert2,45 € TR-07</search>',
                model: 'phi3_5_mini',
              );
            } else {
              expect(request.sessionId, endsWith('::document-no-tools'));
              yield InferenceResponse.finalChunk(
                text: 'Teiera rossa: 24,00 €, quantità 1, codice TR-07.',
                tokensGenerated: 10,
                model: 'phi3_5_mini',
              );
            }
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(
          sendQuery: (_, __) async {
            cloudCalls++;
            return AiResponse(
              text: 'forbidden cloud response',
              model: 'test', tokensUsed: 0,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            );
          },
        ),
        webSearchTool: searchTool,
      );
      final response = await service.infer(const InferenceRequest(
        sessionId: 'pdf-local-s24',
        prompt: 'Qual è il prezzo della teiera rossa? '
            '[Pagina 1/1] Teiera rossa 1 24,00 € TR-07',
        routeDirective: InferenceRouteDirective.localOnly,
        allowWebSearchTool: false,
      ));
      expect(response.text, contains('Teiera rossa: 24,00 €, quantità 1'));
      expect(response.text, isNot(contains('Searching the web')));
      expect(localCalls, 2);
      expect(searchTool.calls, 0);
      expect(cloudCalls, 0);
    });

    test('explicit PDF online query uses only original user wording', () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: 'Public website about teapots.',
          success: true,
        ),
      );
      var localCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel.copyWith(
          id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, _) async* {
            localCalls++;
            if (localCalls == 1) {
              yield InferenceResponse.token(
                text: '<search>PRIVATE PDF CONTENT TR-07 24,00 €</search>',
                model: 'phi3_5_mini',
              );
            } else {
              yield InferenceResponse.finalChunk(
                text: 'Trovate fonti pubbliche.',
                tokensGenerated: 7,
                model: 'phi3_5_mini',
              );
            }
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
        webSearchTool: searchTool,
      );
      final response = await service.infer(const InferenceRequest(
        sessionId: 'pdf-opt-in',
        prompt: 'Dati PDF privati: Teiera rossa 24,00 € TR-07.',
        trustedDocumentWebQuery: 'Verifica online il negozio di teiere.',
        allowWebSearchTool: true,
        routeDirective: InferenceRouteDirective.localOnly,
      ));
      expect(response.text, contains('Trovate fonti pubbliche'));
      expect(searchTool.calls, 1);
      expect(searchTool.lastQuery, 'Verifica online il negozio di teiere.');
      expect(searchTool.lastQuery, isNot(contains('TR-07')));
      expect(localCalls, 2);
    });

    test('optional online PDF verification falls back to LOCAL without connection',
        () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: 'Network unavailable.',
          success: false,
        ),
      );
      var localCalls = 0;
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: validModel.copyWith(
          id: 'phi3_5_mini', localPath: '/tmp/phi.gguf',
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, _) async* {
            localCalls++;
            if (localCalls == 1) {
              yield InferenceResponse.token(
                text: '<search>online shop from PDF</search>',
                model: 'phi3_5_mini',
              );
            } else {
              expect(request.allowWebSearchTool, isFalse);
              expect(request.sessionId, endsWith('::document-no-tools'));
              yield InferenceResponse.finalChunk(
                text: 'Dati PDF locali: Teiera rossa, 24,00 €, TR-07.',
                tokensGenerated: 9,
                model: 'phi3_5_mini',
              );
            }
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(
          configured: false,
        ),
        webSearchTool: searchTool,
      );
      final answer = await service.infer(const InferenceRequest(
        sessionId: 'pdf-web-unavailable',
        prompt: '[Pagina 1/1] Teiera rossa 1 24,00 € TR-07',
        allowWebSearchTool: true,
        trustedDocumentWebQuery: 'Verifica online prezzo teiera rossa.',
        routeDirective: InferenceRouteDirective.localOnly,
      ));
      expect(answer.text, contains('24,00 €'));
      expect(answer.isError, isFalse);
      expect(localCalls, 2);
      expect(searchTool.calls, 1);
      expect(searchTool.lastQuery, 'Verifica online prezzo teiera rossa.');
    });

    test(
        'offline local search tags never execute the web tool and recover locally',
        () async {
      final searchTool = _FakeWebSearchTool(
        const ToolResult(
          toolId: 'web_search',
          output: 'This result must never be used.',
          success: true,
        ),
      );
      var streamInvocations = 0;
      final seenSessionIds = <String>[];
      final service = buildService(
        mode: AiRuntimeMode.local,
        selectedModel: const AiModel(
          id: 'phi3_5_mini',
          displayName: 'Phi-3.5 Mini Instruct',
          fileName: 'phi3.gguf',
          downloadUrl: 'https://example.com/model.gguf',
          version: '1.0.0',
          sizeBytes: 123,
          description: 'Test model',
          isDownloaded: true,
          localPath: '/tmp/phi3.gguf',
          validationStatus: ModelValidationStatus.validatedOk,
        ),
        localRuntimeProvider: FakeLocalRuntimeProvider(
          streamBuilder: (request, cancellationToken) async* {
            streamInvocations += 1;
            seenSessionIds.add(request.sessionId);
            expect(request.isOffline, isTrue);
            expect(cancellationToken.isCancelled, isFalse);

            if (streamInvocations == 1) {
              yield InferenceResponse.token(
                text: '<search>latest weather in Rome</search>',
                model: 'phi3_5_mini',
              );
              return;
            }

            expect(
              request.sessionId,
              'offline-search-s1::offline-search-recovery',
            );
            expect(
              request.prompt,
              contains('local/project knowledge only'),
            );
            expect(
              request.systemPrompt,
              contains('[OFFLINE HARD BOUNDARY]'),
            );
            expect(
              request.systemPrompt,
              contains('What is the latest weather in Rome?'),
            );

            yield InferenceResponse.finalChunk(
              text: 'I cannot verify live weather while offline.',
              tokensGenerated: 7,
              model: 'phi3_5_mini',
            );
          },
        ),
        cloudRuntimeProvider: buildCloudProvider(),
        webSearchTool: searchTool,
      );

      final response = await service.infer(
        const InferenceRequest(
          sessionId: 'offline-search-s1',
          prompt: 'What is the latest weather in Rome?',
          isOffline: true,
        ),
      );

      expect(response.isError, isFalse);
      expect(
        response.text,
        'I cannot verify live weather while offline.',
      );
      expect(searchTool.calls, 0);
      expect(streamInvocations, 2);
      expect(
        seenSessionIds,
        <String>[
          'offline-search-s1',
          'offline-search-s1::offline-search-recovery',
        ],
      );
    });
  });
}

class _FinalThenNaturalCloseProvider extends FakeLocalRuntimeProvider {
  _FinalThenNaturalCloseProvider();

  int prematureCancelCalls = 0;
  int requests = 0;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    var naturalCloseStarted = false;

    final controller = StreamController<InferenceResponse>(
      onCancel: () {
        if (!naturalCloseStarted) {
          prematureCancelCalls += 1;
        }
      },
    );

    controller.onListen = () {
      requests += 1;
      final requestNumber = requests;
      controller.add(
        InferenceResponse.finalChunk(
          text: 'response-$requestNumber',
          tokensGenerated: 1,
          model: request.modelId,
        ),
      );

      Future<void>.delayed(
        const Duration(milliseconds: 5),
        () async {
          naturalCloseStarted = true;
          if (!controller.isClosed) {
            await controller.close();
          }
        },
      );
    };

    return controller.stream;
  }
}

class FakeLocalRuntimeProvider extends LocalRuntimeProvider {
  FakeLocalRuntimeProvider({
    this.responses = const <InferenceResponse>[],
    this.isSupported = true,
    this.streamBuilder,
  });

  final List<InferenceResponse> responses;
  final bool isSupported;
  final TokenStream Function(
    InferenceRequest request,
    CancellationToken cancellationToken,
  )? streamBuilder;

  @override
  bool supportsModel(AiModel model) => isSupported;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    if (streamBuilder != null) {
      yield* streamBuilder!(request, cancellationToken);
      return;
    }
    for (final response in responses) {
      yield response;
    }
  }
}

class _FakeWebSearchTool implements Tool {
  _FakeWebSearchTool(this._result);

  final ToolResult _result;
  var calls = 0;
  String? lastQuery;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Web Search';

  @override
  String get description => 'Fake web search tool for tests.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    calls += 1;
    lastQuery = params['query'] as String?;
    expect(params['query'], isNotEmpty);
    return _result;
  }
}
