import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/assistant_manual_entity_reference_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

class _EntityPersistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  const scopeId = AssistantDurableMemoryContextService.localUserScopeId;
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;
  var timestamp = 0;

  setUp(() {
    timestamp = 100;
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _EntityPersistence()),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
      now: () => ++timestamp,
    );
  });

  test('only explicitly named statements may be manually proposed', () {
    expect(
      AssistantManualEntityReferenceCandidate.recordKeyFor('Jerome è alto.'),
      isNotNull,
    );
    expect(
      AssistantManualEntityReferenceCandidate.recordKeyFor('Kader è un mio collega.'),
      isNotNull,
    );
    expect(
      AssistantManualEntityReferenceCandidate.recordKeyFor('Ho un collega alto.'),
      isNull,
    );
    expect(
      AssistantManualEntityReferenceCandidate.recordKeyFor(
          'Ho comprato una seconda auto rossa.'),
      isNull,
    );
    expect(
      AssistantManualEntityReferenceCandidate.recordKeyFor(
          '«Jerome è alto»'),
      isNull,
    );
  });

  test('no consent or non-user source cannot write', () async {
    for (final gates in <({bool consent, bool direct})>[
      (consent: false, direct: true),
      (consent: true, direct: false),
      (consent: false, direct: false),
    ]) {
      expect(
        await capture.proposeManualEntityReferenceCandidate(
          userPrompt: 'Jerome è alto.',
          consentEnabled: gates.consent,
          directUserMessage: gates.direct,
        ),
        isFalse,
      );
    }
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);
  });

  test('named aliases are separate, candidates invisible until review',
      () async {
    for (final statement in <String>[
      'Jerome è alto.',
      'Kader è un mio collega.',
      'Mika fa tanto sport.',
    ]) {
      expect(
        await capture.proposeManualEntityReferenceCandidate(
          userPrompt: statement,
          consentEnabled: true,
          directUserMessage: true,
        ),
        isTrue,
      );
    }
    final pending =
        await capture.loadReviewableManualEntityReferenceCandidates();
    expect(pending, hasLength(3));
    expect(pending.map((x) => x.recordKey).toSet(), hasLength(3));
    expect(pending.every((x) => x.status == AssistantMemoryStatus.candidate),
        isTrue);
    expect(await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    ), isEmpty);
  });

  test('review protects stale snapshot and disallows changing the named person',
      () async {
    await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Jerome è alto',
      consentEnabled: true,
      directUserMessage: true,
    );
    final candidate =
        (await capture.loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: candidate,
      approve: true,
    ), isFalse);
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: candidate,
      approve: true,
      userConfirmed: true,
      correctedContent: 'Kader è alto',
    ), isFalse);

    await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Jerome è alto',
      consentEnabled: true,
      directUserMessage: true,
    );
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: candidate,
      approve: true,
      userConfirmed: true,
    ), isFalse);
    final fresh =
        (await capture.loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: fresh,
      approve: true,
      userConfirmed: true,
    ), isTrue);
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    );
    expect(confirmed, hasLength(1));
    expect(confirmed.single.content, 'Jerome è alto');
    expect(confirmed.single.source, AssistantMemorySource.userExplicit);
  });

  test('rejected candidate never enters confirmed recall', () async {
    await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Mika fa tanto sport',
      consentEnabled: true,
      directUserMessage: true,
    );
    final candidate =
        (await capture.loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: candidate,
      approve: false,
      userConfirmed: true,
    ), isTrue);
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);
    expect(await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    ), isEmpty);
  });
}
