import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  test('Workshop sends current user text only as prompt, not duplicated in context',
      () async {
    final provider = _CapturingProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    await controller.send('prima richiesta');

    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.prompt, 'prima richiesta');
    expect(provider.requests.single.context, isEmpty);
    expect(
      provider.requests.single.systemPrompt,
      contains('piu piccolo MVP realmente costruibile'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('Non aggiungere funzionalita'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains("stessa lingua dell'ultimo messaggio"),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('Se il messaggio corrente e in italiano, rispondi in italiano'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('builder remoto GitHub Actions'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('modalita locale/offline usa invece la toolchain locale'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('setup/download interno previsto dal prodotto'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('non prerequisiti manuali dell\'utente'),
    );
    expect(
      provider.requests.single.systemPrompt,
      contains('non come prerequisito per generare o compilare'),
    );

    await controller.send('seconda richiesta');

    expect(provider.requests, hasLength(2));
    final second = provider.requests.last;
    expect(second.prompt, 'seconda richiesta');
    expect(
      second.context.map((turn) => (turn.role, turn.content)).toList(),
      <(ChatRole, String)>[
        (ChatRole.user, 'prima richiesta'),
        (ChatRole.assistant, 'risposta Cantiere'),
      ],
    );
    expect(
      second.context.where((turn) => turn.content == second.prompt),
      isEmpty,
    );

    controller.dispose();
  });

  test('Workshop clarification is not marked ready for approval',
      () async {
    final provider = _SingleReplyProvider(
      'CLARIFY: Qual è la funzione principale?',
    );
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    final result = await controller.send('fammi una app');

    expect(result, isNotNull);
    expect(result!.content, 'Qual è la funzione principale?');
    expect(
      controller.lastReplyKind,
      WorkshopChatReplyKind.clarification,
    );
    expect(controller.lastResponseReadyForApproval, isFalse);

    controller.dispose();
  });


  test('Workshop retries a clearly truncated conversational proposal once',
      () async {
    final provider = _ScriptedReplyProvider(<InferenceResponse>[
      InferenceResponse.finalChunk(
        text:
            'PROPOSAL: Creo una app Contatore Test con un numero centrale, '
            'pulsante piu e pulsante Azzera. Il progetto restera senza package '
            'esterni e sara pronto per essere compilato e testato su',
        tokensGenerated: 384,
        model: 'fake-workshop',
      ),
      InferenceResponse.finalChunk(
        text:
            'PROPOSAL: Creo una app Contatore Test con numero centrale, '
            'pulsante + e pulsante Azzera, senza package esterni. '
            'La produzione generera il minimo progetto Flutter richiesto.',
        tokensGenerated: 38,
        model: 'fake-workshop',
      ),
    ]);
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    final result = await controller.send('crea contatore');

    expect(result, isNotNull);
    expect(result!.content, endsWith('richiesto.'));
    expect(controller.lastResponseReadyForApproval, isTrue);
    expect(provider.requests, hasLength(2));
    expect(provider.requests.first.maxTokens, 384);
    expect(provider.requests.last.maxTokens, 384);
    expect(
      provider.requests.last.sessionId,
      'workshop:retry-truncated-1',
    );
    expect(
      provider.requests.last.systemPrompt,
      contains('senza codice sorgente'),
    );

    controller.dispose();
  });

  test('Workshop collector does not duplicate cumulative final snapshot',
      () async {
    final provider = _CumulativeSnapshotProvider();
    final controller = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
    );

    final result = await controller.send('costruisci app');

    expect(result, isNotNull);
    expect(result!.content, 'Hello world');
    expect(
      controller.messages
          .where((turn) => turn.role == ChatRole.assistant)
          .map((turn) => turn.content)
          .toList(),
      <String>['Hello world'],
    );

    controller.dispose();
  });

}



final class _ScriptedReplyProvider implements RuntimeInferenceProvider {
  _ScriptedReplyProvider(this.responses);

  final List<InferenceResponse> responses;
  final List<InferenceRequest> requests = <InferenceRequest>[];
  int _index = 0;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    requests.add(request);
    if (_index >= responses.length) {
      throw StateError('Unexpected Workshop chat retry.');
    }
    yield responses[_index++];
  }
}

final class _SingleReplyProvider implements RuntimeInferenceProvider {
  _SingleReplyProvider(this.reply);

  final String reply;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    yield InferenceResponse.finalChunk(
      text: reply,
      tokensGenerated: 4,
      model: 'fake-workshop',
    );
  }
}

final class _CumulativeSnapshotProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    yield InferenceResponse.token(
      text: 'Hello ',
      model: 'fake-workshop',
    );
    yield InferenceResponse.token(
      text: 'world',
      model: 'fake-workshop',
    );
    yield InferenceResponse.finalChunk(
      text: 'Hello world',
      tokensGenerated: 2,
      model: 'fake-workshop',
    );
  }
}

final class _CapturingProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    requests.add(request);

    yield InferenceResponse.finalChunk(
      text: 'risposta Cantiere',
      tokensGenerated: 2,
      model: 'fake-workshop',
    );
  }
}
