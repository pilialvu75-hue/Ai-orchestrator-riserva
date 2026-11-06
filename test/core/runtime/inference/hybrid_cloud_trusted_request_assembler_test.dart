import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_prompt_provenance.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_trusted_request_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryPersistence implements AssistantDurableMemoryPersistence {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
}

void main() {
  const history = <AiMessage>[
    AiMessage(role: AiMessageRole.user, content: 'Previous private message'),
  ];

  test('a real confirmed memory and source-backed RAG seal every field',
      () async {
    final memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: _MemoryPersistence(),
      ),
    );
    await memory.recordConfirmed(
      recordKey: 'bike.current',
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      kind: AssistantMemoryKind.fact,
      content: 'La bici attuale è blu.',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 20,
    );
    final confirmed = await AssistantDurableMemoryContextService(
      memoryService: memory,
    ).buildConfirmedContextWithProvenance(
      sessionId: 'conversation-1',
      userPrompt: 'Quali sono i dettagli della mia bici?',
    );
    expect(confirmed, isNotNull);
    final verified = confirmed!;

    final rag = HybridCloudPromptProvenance.fromDocumentContext(
      originalQuestion: 'Quali sono i dettagli della mia bici?',
      fallbackInstruction: 'Summarize the document',
      beforeExcerpt: '\n\n[LOCAL EXCERPTS]\n',
      retrievedExcerpt: '[bici.txt] Il numero privato è 1234',
      afterExcerpt: '\n[END EXCERPTS]',
    );
    final request = AiRequest(
      prompt: rag.prompt,
      systemPrompt: 'You are Aivexus\n\n' + verified.text,
      providerId: 'gemini',
      modelId: 'gemini-test',
      maxTokens: 1024,
      messages: history,
    );
    final sealed = HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner-1',
      sessionId: 'local-session',
      accountId: 'account-1',
      purpose: 'Answer with approved user context',
      request: request,
      originalQuestion: 'Quali sono i dettagli della mia bici?',
      exactBaseSystemPrompt: 'You are Aivexus',
      historySnapshot: history,
      documentPrompt: rag,
      confirmedMemory: verified,
    );
    expect(sealed.request.prompt, request.prompt);
    expect(sealed.request.systemPrompt, request.systemPrompt);
    expect(sealed.disclosure.scopes, contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.documentExcerpt,
      HybridDisclosureSensitivity.unknown,
    )));
    expect(sealed.disclosure.scopes, contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.durableMemory,
      HybridDisclosureSensitivity.unknown,
    )));
    expect(sealed.disclosure.scopes, contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.conversationHistory,
      HybridDisclosureSensitivity.unknown,
    )));
    expect(sealed.disclosure.outboundText, contains('1234'));
    expect(sealed.disclosure.outboundText, contains('La bici attuale è blu.'));

    // A web/tool result appended inside the system prompt, or a different
    // conversation role, is not silently accepted as approved memory.
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner-1', sessionId: 'local-session',
      accountId: 'account-1', purpose: 'Answer',
      request: AiRequest(
        prompt: rag.prompt,
        systemPrompt: request.systemPrompt! + '\nSECRET TOOL RESULT',
        providerId: 'gemini', modelId: 'gemini-test', maxTokens: 1024,
        messages: history,
      ),
      originalQuestion: 'Quali sono i dettagli della mia bici?',
      exactBaseSystemPrompt: 'You are Aivexus',
      historySnapshot: history,
      documentPrompt: rag,
      confirmedMemory: verified,
    ), throwsStateError);
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner-1', sessionId: 'local-session',
      accountId: 'account-1', purpose: 'Answer',
      request: request,
      originalQuestion: 'Changed question',
      exactBaseSystemPrompt: 'You are Aivexus',
      historySnapshot: history,
      documentPrompt: rag,
      confirmedMemory: verified,
    ), throwsStateError);
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner-1', sessionId: 'local-session',
      accountId: 'account-1', purpose: 'Answer',
      request: request,
      originalQuestion: 'Quali sono i dettagli della mia bici?',
      exactBaseSystemPrompt: 'You are Aivexus',
      historySnapshot: const <AiMessage>[
        AiMessage(role: AiMessageRole.assistant, content: 'Previous private message'),
      ],
      documentPrompt: rag,
      confirmedMemory: verified,
    ), throwsStateError);
  });

  test('plain user question seals without inventing memories', () {
    final seal = HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner-1',
      sessionId: 'session-1',
      accountId: 'account-a',
      purpose: 'Answer the question',
      request: const AiRequest(
        prompt: 'Hello',
        systemPrompt: 'Speak Italian',
        modelId: 'gpt-test',
        providerId: 'openAi',
        maxTokens: 1024,
      ),
      originalQuestion: ' Hello ',
      exactBaseSystemPrompt: 'Speak Italian',
      historySnapshot: const <AiMessage>[],
    );
    expect(seal.disclosure.scopes, isNot(contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.durableMemory,
      HybridDisclosureSensitivity.unknown,
    ))));
    expect(seal.request.prompt, 'Hello');
    expect(seal.disclosure.scopes, contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.currentQuestion,
      HybridDisclosureSensitivity.unknown,
    )));
  });

  test('unknown payload additions and tools cannot receive a valid seal', () {
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'o', sessionId: 's', accountId: 'a', purpose: 'answer',
      request: const AiRequest(
        prompt: 'Hello + secret',
        modelId: 'gpt-test', providerId: 'openAi',
      ),
      originalQuestion: 'Hello',
      exactBaseSystemPrompt: '',
      historySnapshot: const <AiMessage>[],
    ), throwsStateError);
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'o', sessionId: 's', accountId: 'a', purpose: 'answer',
      request: const AiRequest(
        prompt: 'Hello',
        modelId: 'gpt-test', providerId: 'openAi',
        tools: <Map<String, dynamic>>[<String, dynamic>{'name': 'private tool'}],
      ),
      originalQuestion: 'Hello',
      exactBaseSystemPrompt: '',
      historySnapshot: const <AiMessage>[],
    ), throwsStateError);
    expect(() => HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'o', sessionId: 's', accountId: 'a', purpose: 'answer',
      request: const AiRequest(
        prompt: 'Hello',
        modelId: 'gpt-test', providerId: 'openAi',
        metadata: <String, dynamic>{'hidden': 'private metadata'},
      ),
      originalQuestion: 'Hello',
      exactBaseSystemPrompt: '',
      historySnapshot: const <AiMessage>[],
    ), throwsStateError);
  });
}
