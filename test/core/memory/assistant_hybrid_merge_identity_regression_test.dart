import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/assistant_manual_entity_reference_candidate.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_confirmed_memory_provenance.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:flutter_test/flutter_test.dart';

/// H45 integration gate: ME-2's named-reference guard and HYBRID's exact
/// confirmed-memory provenance MUST coexist after a periodic main merge.
final class _MemoryStoreFixture implements AssistantDurableMemoryPersistence {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }
}

void main() {
  test('H45 named people stay isolated in HYBRID confirmed-memory evidence',
      () async {
    final memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _MemoryStoreFixture()),
    );
    const userScope = AssistantDurableMemoryContextService.localUserScopeId;
    for (final item in <({String claim, int time})>[
      (claim: 'Jerome è alto', time: 100),
      (claim: 'Kader è un mio collega', time: 110),
    ]) {
      final key = AssistantManualEntityReferenceCandidate.recordKeyFor(
        item.claim,
      );
      expect(key, isNotNull);
      await memory.recordConfirmed(
        recordKey: key!,
        scope: AssistantMemoryScope.user,
        scopeId: userScope,
        kind: AssistantMemoryKind.fact,
        content: item.claim,
        source: AssistantMemorySource.userExplicit,
        updatedAt: item.time,
      );
    }
    final retrieval = AssistantDurableMemoryContextService(
      memoryService: memory,
    );

    final jerome = await retrieval.buildConfirmedContextWithProvenance(
      sessionId: 'new-chat-different-model',
      userPrompt: 'Jerome è alto?',
    );
    expect(jerome, isNotNull);
    expect(jerome!.text, contains('Jerome è alto'));
    expect(jerome.text, isNot(contains('Kader')));

    final segments = HybridCloudConfirmedMemoryProvenance.toDisclosureSegments(
      source: jerome,
      exactContext: jerome.text,
    );
    expect(segments.map((part) => part.text).join(), jerome.text);
    expect(segments.last.scope.origin, HybridDisclosureOrigin.durableMemory);
    expect(segments.last.scope.sensitivity,
        HybridDisclosureSensitivity.unknown);
    expect(segments.first.text, isNot(contains('Jerome è alto')));

    final kader = await retrieval.buildConfirmedContextWithProvenance(
      sessionId: 'another-chat-same-user',
      userPrompt: 'Kader è un mio collega?',
    );
    expect(kader, isNotNull);
    expect(kader!.text, contains('Kader è un mio collega'));
    expect(kader.text, isNot(contains('Jerome')));

    // Neither an adjective nor an autobiographical query identifies a
    // reviewed third party. No third-party context may be disclosed.
    expect(await retrieval.buildConfirmedContextWithProvenance(
      sessionId: 'new-chat',
      userPrompt: 'Chi è alto?',
    ), isNull);
    expect(await retrieval.buildConfirmedContextWithProvenance(
      sessionId: 'new-chat',
      userPrompt: 'Cosa sai di me?',
    ), isNull);
  });

  test('H45 short alias never authorizes cross-model memory recall',
      () async {
    final memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _MemoryStoreFixture()),
    );
    const statement = 'Li è alto';
    await memory.recordConfirmed(
      recordKey: AssistantManualEntityReferenceCandidate.recordKeyFor(
        statement,
      )!,
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      kind: AssistantMemoryKind.fact,
      content: statement,
      source: AssistantMemorySource.userExplicit,
      updatedAt: 100,
    );
    final retrieval = AssistantDurableMemoryContextService(
      memoryService: memory,
    );
    expect(await retrieval.buildConfirmedContextWithProvenance(
      sessionId: 'fresh-hybrid-local-chat',
      userPrompt: 'Chi è alto?',
    ), isNull);
  });
}
