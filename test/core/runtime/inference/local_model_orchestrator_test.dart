import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_model_orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

void main() {
  const router = LocalModelOrchestrator();

  AiModel installed(String id, int size) => AiModel(
    id: id,
    displayName: id,
    fileName: '$id.gguf',
    downloadUrl: '',
    version: '1',
    sizeBytes: size,
    description: '',
    isDownloaded: true,
    localPath: '/models/$id.gguf',
    validationStatus: ModelValidationStatus.validatedOk,
  );

  final phi = installed('phi3_5_mini', 2200000000);
  final qwen = installed('qwen2_5_3b_instruct', 1800000000);

  AiModel? route(
    String prompt, {
    Iterable<AiModel>? models,
    AiModel? preferred,
    ResourceSample? memory,
    bool android = false,
    bool Function(AiModel)? supports,
    List<ChatTurn> context = const [],
    String? lastCompletedModelId,
    int successfulTurnsSinceSwitch = 99,
  }) => router.select(
    request: InferenceRequest(
      sessionId: 'test',
      prompt: prompt,
      context: context,
    ),
    availableModels: models ?? [phi, qwen],
    preferredModel: preferred ?? phi,
    supportsModel: supports ?? (_) => true,
    resources: memory,
    isAndroid: android,
    lastCompletedModelId: lastCompletedModelId,
    successfulTurnsSinceSwitch: successfulTurnsSinceSwitch,
  );

  test('ordinary chat sticks to the manual favorite where possible', () {
    expect(route('Ciao, come stai?')?.id, phi.id);
  });

  test('code and translation can choose a different validated model', () {
    expect(route('Scrivi codice Dart')?.id, qwen.id);
    expect(route('Traduci in francese questo messaggio')?.id, qwen.id);
    expect(route('Analizza la logica del problema')?.id, phi.id);
  });

  test('short follow-ups use the last user topic, not assistant text', () {
    expect(route('continua', context: const [
      ChatTurn(role: ChatRole.user, content: 'Scrivi codice Dart'),
      ChatTurn(role: ChatRole.assistant, content: 'Il testo è irrilevante'),
    ])?.id, qwen.id);
  });

  test('invalid or unsupported models never participate', () {
    final invalid = qwen.copyWith(
      validationStatus: ModelValidationStatus.invalidModel,
    );
    expect(route('Scrivi codice', models: [phi, invalid])?.id, phi.id);
    expect(
      route('Scrivi codice', supports: (m) => m.id != qwen.id)?.id,
      phi.id,
    );
    expect(route('Scrivi codice', models: []) , isNull);
  });

  test('Android memory pressure avoids large weights instead of crashing', () {
    final memory = ResourceSample({
      'availableBytes': 150000000,
      'thresholdBytes': 300000000,
      'totalBytes': 8000000000,
      'lowMemory': true,
    });
    expect(
      route('Analizza la logica', memory: memory, android: true)?.id,
      qwen.id,
    );
    expect(
      route('Analizza', models: [phi], memory: memory, android: true),
      isNull,
    );
  });

  test('unknown Android RAM does not authorize heavyweight models', () {
    final huge = installed('nemotron_8b', 5400000000);
    expect(
      route('Analizza la logica', models: [huge, qwen], android: true)?.id,
      qwen.id,
    );
  });
  test('same chat stays on the completed specialist after coding turn', () {
    // With a single successful code answer, an ordinary follow-up should
    // not reload Phi solely because Phi remains selected in MANUAL settings.
    expect(route('Chi pratica sport?',
      lastCompletedModelId: qwen.id)?.id, qwen.id);
    expect(route('continua',
      lastCompletedModelId: qwen.id,
      context: const [
        ChatTurn(role: ChatRole.user, content: 'Scrivi codice Dart'),
      ])?.id, qwen.id);
  });

  test('Android requires a larger task gain than desktop to reload a model', () {
    expect(route('Scrivi codice Dart',
      lastCompletedModelId: phi.id,
      android: true)?.id, phi.id);
    expect(route('Scrivi codice Dart',
      lastCompletedModelId: phi.id)?.id, qwen.id);
  });

  test('cooldown stops A to B to A immediately after a successful switch', () {
    final coder = installed('codegemma_2b', 1600000000);
    final decision = router.decide(
      request: const InferenceRequest(
          sessionId: 'chat', prompt: 'Scrivi codice Dart'),
      availableModels: [phi, coder],
      preferredModel: phi,
      supportsModel: (_) => true,
      lastCompletedModelId: phi.id,
      successfulTurnsSinceSwitch: 0,
    );
    expect(decision.model?.id, phi.id);
    expect(decision.reason, LocalModelRoutingReason.keptCooldown);

    final later = router.decide(
      request: const InferenceRequest(
          sessionId: 'chat', prompt: 'Scrivi codice Dart'),
      availableModels: [phi, coder],
      preferredModel: phi,
      supportsModel: (_) => true,
      lastCompletedModelId: phi.id,
      successfulTurnsSinceSwitch: 3,
    );
    expect(later.model?.id, coder.id);
    expect(later.reason, LocalModelRoutingReason.switchedForTask);
  });

  test('memory guard beats affinity and removed models cannot remain pinned', () {
    final memory = ResourceSample({
      'availableBytes': 160000000,
      'thresholdBytes': 300000000,
      'totalBytes': 8000000000,
      'lowMemory': true,
    });
    expect(route('Spiega il problema',
      lastCompletedModelId: phi.id,
      memory: memory,
      android: true)?.id, qwen.id);
    expect(route('Ciao',
      lastCompletedModelId: phi.id,
      models: [qwen])?.id, qwen.id);
  });

  test('session affinity retains model only after success and is bounded', () {
    final affinity = LocalSessionModelAffinity(maxSessions: 2);
    expect(affinity.get('chat-a'), isNull);
    affinity.recordSuccess('chat-a', phi.id);
    expect(affinity.get('chat-a')?.modelId, phi.id);
    expect(affinity.get('chat-a')?.successfulTurnsSinceSwitch, 99);
    affinity.recordSuccess('chat-a', qwen.id);
    expect(affinity.get('chat-a')?.successfulTurnsSinceSwitch, 0);
    affinity.recordSuccess('chat-a', qwen.id);
    expect(affinity.get('chat-a')?.successfulTurnsSinceSwitch, 1);
    affinity.recordSuccess('chat-b', phi.id);
    affinity.recordSuccess('chat-c', qwen.id);
    expect(affinity.get('chat-a'), isNull);
    expect(affinity.get('chat-b')?.modelId, phi.id);
    affinity.reset();
    expect(affinity.get('chat-c'), isNull);
  });

}
