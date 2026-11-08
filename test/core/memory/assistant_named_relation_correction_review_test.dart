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
