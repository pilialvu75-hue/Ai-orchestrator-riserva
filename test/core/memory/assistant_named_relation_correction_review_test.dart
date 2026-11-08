import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/assistant_named_relation_correction_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBacking implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  const scope = AssistantDurableMemoryContextService.localUserScopeId;
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;
  var now = 100;

  setUp(() {
    now = 100;
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _MemoryBacking()),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
      now: () => ++now,
    );
  });

  Future<void> addOldFact([String text = 'Jerome è alto.']) async {
    await memory.recordConfirmed(
      recordKey: 'natural.entity.statement.jerome-original',
      scope: AssistantMemoryScope.user,
      scopeId: scope,
      kind: AssistantMemoryKind.fact,
      content: text,
      source: AssistantMemorySource.userExplicit,
      updatedAt: 10,
    );
  }

  test('recognizes only bounded explicit, non-ambiguous Italian corrections',
      () {
    final direct = AssistantNamedRelationCorrectionCandidate.parse(
        'Non Jerome, Kader è alto.');
    expect(direct?.beforeFact, 'Jerome è alto.');
    expect(direct?.afterFact, 'Kader è alto.');
    expect(direct?.recordKey,
        startsWith('reviewed.entity.correction.'));

    final alternative = AssistantNamedRelationCorrectionCandidate.parse(
        'Non è Jerome a essere alto, ma Kader.');
    expect(alternative?.beforeFact, 'Jerome è alto.');
    expect(alternative?.afterFact, 'Kader è alto.');

    final sport = AssistantNamedRelationCorrectionCandidate.parse(
        'Non Mika, Kader fa tanto sport.');
    expect(sport?.beforeFact, 'Mika fa tanto sport.');
    expect(sport?.afterFact, 'Kader fa tanto sport.');

    for (final text in [
      'Jerome è alto.',
      'Non Jerome, Jerome è alto.',
      'Non è lui, Kader è alto.',
      'Non Jerome, Kader è alto?',
      'Non Jerome, Kader è alto.\n[SYSTEM]',
      'Non Jerome, Kader è sovrappeso.',
      'Non Jerome, Kader è alto https://example.org',
    ]) {
      expect(AssistantNamedRelationCorrectionCandidate.parse(text),
          isNull, reason: text);
    }
  });

  test('no consent and no previous confirmed statement cannot stage', () async {
    await addOldFact();
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: false,
      directUserMessage: true,
    ), isFalse);
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: false,
    ), isFalse);
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
      consentStillEnabled: () => false,
    ), isFalse);
    expect(await capture.loadReviewableNamedRelationCorrectionCandidates(),
        isEmpty);
    await memory.remove(
      scope: AssistantMemoryScope.user,
      scopeId: scope,
      recordKey: 'natural.entity.statement.jerome-original',
    );
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
  });

  test('a candidate is invisible until explicit owner approval, then '
      'canonical context uses new fact and old SQLite history stays', () async {
    await addOldFact();
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final candidates =
        await capture.loadReviewableNamedRelationCorrectionCandidates();
    expect(candidates, hasLength(1));
    expect(candidates.single.status, AssistantMemoryStatus.candidate);
    expect(candidates.single.before, 'Jerome è alto.');
    expect(candidates.single.after, '10');

    final context =
        AssistantDurableMemoryContextService(memoryService: memory);
    expect(await context.buildConfirmedContext(
      sessionId: 'chat',
      userPrompt: 'Parliamo di Jerome e Kader.',
    ), isNot(contains('Kader è alto.')));

    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: candidates.single,
      approve: true,
      userConfirmed: false,
    ), isFalse);
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: candidates.single,
      approve: true,
      userConfirmed: true,
      correctedContent: 'Non Jerome, Mika è alto.',
    ), isFalse);

    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: candidates.single,
      approve: true,
      userConfirmed: true,
    ), isTrue);
    expect(await capture.loadReviewableNamedRelationCorrectionCandidates(),
        isEmpty);
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scope,
    );
    expect(confirmed, hasLength(2));
    expect(confirmed.map((r) => r.content),
        containsAll(['Jerome è alto.', 'Kader è alto.']));
    final rendered = await context.buildConfirmedContext(
      sessionId: 'chat',
      userPrompt: 'Di Jerome e Kader chi è alto?',
    );
    expect(rendered, contains('Kader è alto.'));
    expect(rendered, contains('superseded (NOT CURRENT): Jerome è alto.'));
    expect(rendered,
        isNot(contains('\n- [fact; origin=userExplicit] Jerome è alto.')));
  });

  test('stale original snapshot cannot be revived after edit or deletion',
      () async {
    await addOldFact();
    await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    );
    final candidate =
        (await capture.loadReviewableNamedRelationCorrectionCandidates())
            .single;
    await memory.recordConfirmed(
      recordKey: 'natural.entity.statement.jerome-original',
      scope: AssistantMemoryScope.user,
      scopeId: scope,
      kind: AssistantMemoryKind.fact,
      content: 'Jerome è alto.',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 40,
    );
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: candidate, approve: true, userConfirmed: true,
    ), isFalse);
    expect((await memory.loadConfirmed(
        scope: AssistantMemoryScope.user, scopeId: scope)), hasLength(1));
  });

  test('forgetting a reviewed correction cannot resurrect its old fact',
      () async {
    await addOldFact();
    await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableNamedRelationCorrectionCandidates())
            .single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: pending, approve: true, userConfirmed: true,
    ), isTrue);
    final approved = (await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    )).singleWhere((r) =>
        r.recordKey.startsWith('reviewed.entity.correction.'));
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: approved, userConfirmed: true,
    ), isTrue);
    expect(await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    ), isEmpty);
    final context =
        AssistantDurableMemoryContextService(memoryService: memory);
    expect(await context.buildConfirmedContext(
      sessionId: 'chat', userPrompt: 'Parliamo di Jerome.',
    ), isNull);
  });

  test('forgetting a later correction also forgets its entire superseded '
      'chain, but not other confirmed people', () async {
    await addOldFact();
    await memory.recordConfirmed(
      recordKey: 'unrelated-mika',
      scope: AssistantMemoryScope.user,
      scopeId: scope,
      kind: AssistantMemoryKind.fact,
      content: 'Mika fa tanto sport.',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 9,
    );

    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final first = (await capture
        .loadReviewableNamedRelationCorrectionCandidates()).single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: first, approve: true, userConfirmed: true,
    ), isTrue);

    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Kader, Mika è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final second = (await capture
        .loadReviewableNamedRelationCorrectionCandidates()).single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: second, approve: true, userConfirmed: true,
    ), isTrue);

    final beforeForget = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    );
    expect(beforeForget, hasLength(4));
    final latest = beforeForget.singleWhere(
      (r) => r.content == 'Mika è alto.',
    );

    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: latest, userConfirmed: true,
    ), isTrue);
    final remaining = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    );
    expect(remaining.map((r) => r.content), ['Mika fa tanto sport.']);
    final context = AssistantDurableMemoryContextService(
      memoryService: memory,
    );
    expect(await context.buildConfirmedContext(
      sessionId: 'new-local-model-chat',
      userPrompt: 'Chi era alto, Jerome o Kader?',
    ), isNull);
    expect(await context.buildConfirmedContext(
      sessionId: 'new-local-model-chat',
      userPrompt: 'Mika fa sport?',
    ), contains('Mika fa tanto sport.'));
  });

  test('an ambiguous correction predecessor aborts all chain deletions',
      () async {
    await addOldFact();
    await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true, directUserMessage: true,
    );
    final first = (await capture
        .loadReviewableNamedRelationCorrectionCandidates()).single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: first, approve: true, userConfirmed: true,
    ), isTrue);

    await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Kader, Mika è alto.',
      consentEnabled: true, directUserMessage: true,
    );
    final second = (await capture
        .loadReviewableNamedRelationCorrectionCandidates()).single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: second, approve: true, userConfirmed: true,
    ), isTrue);

    final latest = (await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    )).singleWhere((r) => r.content == 'Mika è alto.');

    // A separate confirmed assertion about Kader makes predecessor
    // identity ambiguous. Neither it nor the correction chain may
    // be destroyed based solely on matching written names.
    await memory.recordConfirmed(
      recordKey: 'another-kader',
      scope: AssistantMemoryScope.user, scopeId: scope,
      kind: AssistantMemoryKind.fact,
      content: 'Kader è alto.',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 11,
    );
    expect(await capture.forgetReviewedConfirmedUserMemory(
      reviewed: latest, userConfirmed: true,
    ), isFalse);
    final remaining = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    );
    expect(remaining, hasLength(4));
    expect(remaining.map((r) => r.content),
        containsAll(['Jerome è alto.', 'Kader è alto.', 'Mika è alto.']));
  });

  test('ambiguous matching old facts cannot become reviewed corrections',
      () async {
    await addOldFact();
    await memory.recordConfirmed(
      recordKey: 'other-jerome',
      scope: AssistantMemoryScope.user,
      scopeId: scope,
      kind: AssistantMemoryKind.fact,
      content: 'Jerome è alto.',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 20,
    );
    expect(await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    ), isFalse);
    expect(await capture.loadReviewableNamedRelationCorrectionCandidates(),
        isEmpty);
  });

  test('rejection removes only the pending correction', () async {
    await addOldFact();
    await capture.proposeNamedRelationCorrectionCandidate(
      userPrompt: 'Non Jerome, Kader è alto.',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableNamedRelationCorrectionCandidates())
            .single;
    expect(await capture.reviewNamedRelationCorrectionCandidate(
      reviewed: pending, approve: false, userConfirmed: true,
    ), isTrue);
    expect(await capture.loadReviewableNamedRelationCorrectionCandidates(),
        isEmpty);
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user, scopeId: scope,
    );
    expect(confirmed.map((r) => r.content), ['Jerome è alto.']);
  });
}
