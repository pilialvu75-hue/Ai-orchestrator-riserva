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

  test('local retrieval never confuses named colleagues or exposes them as me',
      () async {
    await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Jerome è alto',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: pending,
      approve: true,
      userConfirmed: true,
    ), isTrue);

    final context = AssistantDurableMemoryContextService(memoryService: memory);
    expect(await context.buildConfirmedContext(
      sessionId: 'new-chat-another-model',
      userPrompt: 'Jerome è alto?',
    ), contains('Jerome è alto'));
    expect(await context.buildConfirmedContext(
      sessionId: 'new-chat-another-model',
      userPrompt: 'Kader è alto?',
    ), isNull);
    expect(await context.buildConfirmedContext(
      sessionId: 'new-chat-another-model',
      userPrompt: 'Cosa sai di me?',
    ), isNull);
  });

  test('short name cannot bypass named third-party retrieval guard', () async {
    await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Li è alto',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: pending,
      approve: true,
      userConfirmed: true,
    ), isTrue);

    final context = AssistantDurableMemoryContextService(memoryService: memory);
    expect(await context.buildConfirmedContext(
      sessionId: 'different-chat',
      userPrompt: 'Chi è alto?',
    ), isNull);
    expect(await context.buildConfirmedContext(
      sessionId: 'different-chat',
      userPrompt: 'Cosa sai di me?',
    ), isNull);
  });

  test('exact current fact cannot be proposed twice after approval',
      () async {
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Jerome è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final first = (await capture
        .loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: first, approve: true, userConfirmed: true,
    ), isTrue);

    // Different trailing punctuation and casing are the same user-stated fact.
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'jerome è alto',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Jerome è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);
    final saved = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scopeId,
    );
    expect(saved, hasLength(1));
    expect(saved.single.status, AssistantMemoryStatus.confirmed);
    expect(saved.single.content, 'Jerome è alto.');
    // A different stated named fact can still become a candidate.
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        hasLength(1));
  });

  test('superseded history stays confirmed and cannot be overwritten',
      () async {
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Luca è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final old = (await capture
        .loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: old, approve: true, userConfirmed: true,
    ), isTrue);

    // A candidate may already be pending before the correction is approved.
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Nino è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final duplicateBeforeReview = (await capture
        .loadReviewableManualEntityReferenceCandidates()).single;
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Luca, Nino è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final replacement = (await capture
        .loadReviewableNamedRelationCorrectionCandidates()).single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: replacement, approve: true, userConfirmed: true,
    ), isTrue);

    // The now-redundant proposal is hidden and cannot be approved from a
    // stale screen even though audit history in SQLite is preserved.
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);
    expect(await capture.reviewManualEntityReferenceCandidate(
      reviewed: duplicateBeforeReview, approve: true, userConfirmed: true,
    ), isFalse);
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Nino è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
    // Repeating the superseded Luca statement must not downgrade the
    // historical confirmed record to a candidate.
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Luca è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
    final history = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scopeId,
    );
    expect(history.map((r) => r.content).toSet(),
        containsAll(<String>['Luca è alto.', 'Nino è alto.']));
    expect(history.every((r) => r.status == AssistantMemoryStatus.confirmed),
        isTrue);

    // Unreviewed new body-characteristic descriptions must not be inferred
    // as confirmed memories merely because the model mentions them.
    expect(await capture.proposeManualEntityReferenceCandidate(
      userPrompt: 'Nino è grasso.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
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
