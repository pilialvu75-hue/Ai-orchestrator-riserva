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
}
