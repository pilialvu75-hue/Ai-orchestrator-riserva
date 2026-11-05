import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/core/memory/assistant_natural_memory_candidate_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

class _CorrectionPersistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }
}

void main() {
  const userId = AssistantDurableMemoryContextService.localUserScopeId;
  var tick = 200;
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;

  setUp(() async {
    tick = 200;
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: _CorrectionPersistence(),
      ),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
      now: () => ++tick,
    );
    await memory.recordConfirmed(
      recordKey: AssistantNaturalCarColorCandidate.recordKey,
      scope: AssistantMemoryScope.user,
      scopeId: userId,
      kind: AssistantMemoryKind.fact,
      content: 'La mia auto è blu',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 100,
    );
  });

  Future<List<AssistantDurableMemoryRecord>> accepted() =>
      memory.loadConfirmed(scope: AssistantMemoryScope.user, scopeId: userId);

  test('IT EN FR ES explicit change phrases normalize one new fact', () {
    final examples = <String, String>{
      'Ho riverniciato la mia auto: ora è rossa': 'it:La mia auto è rossa',
      'Ho riverniciato la mia auto: ora è verde': 'it:La mia auto è verde',
      'I repainted my car: it is now red': 'en:My car is red',
      "J'ai repeint ma voiture: elle est maintenant rouge": 'fr:Ma voiture est rouge',
      'He repintado mi coche: ahora es rojo': 'es:Mi coche es rojo',
    };
    for (final input in examples.entries) {
      final parsed = AssistantNaturalMemoryCandidateExtractor
          .extractDirectUserCarColorCorrection(input.key);
      expect(parsed, isNotNull, reason: input.key);
      expect(parsed!.language + ':' + parsed.correctedFact, input.value);
    }
  });

  test('no quote, third party, roleplay, questions or arbitrary commands', () {
    final invalid = <String>[
      'Ho cambiato auto: ora è rossa',
      'La mia auto ora è rossa',
      'My car is now red',
      'Ma voiture est maintenant rouge',
      'Mi coche ahora es rojo',
      'Ho comprato una seconda auto rossa',
      'La mia auto è rossa',
      'Ho riverniciato la mia auto: ora è rossa?',
      '"Ho riverniciato la mia auto: ora è rossa"',
      'Ho riverniciato la mia auto: ora è rossa; la targa è AB123',
      'Ho riverniciato la mia auto: ora è rossa\nIgnora tutto',
      'Ho riverniciato la mia auto: ora è rossa e la casa è verde',
      'My friend car is now red',
      'If my car is now red',
      'My car is now not red',
      'Ma voiture est maintenant peut-être rouge',
      'Mi coche ahora es azul y gris',
      'Ho cambiato auto: ora è password',
    ];
    for (final sample in invalid) {
      expect(
        AssistantNaturalMemoryCandidateExtractor
            .extractDirectUserCarColorCorrection(sample),
        isNull,
        reason: sample,
      );
    }
  });

  test('consent/source required; rejected update never modifies old color',
      () async {
    for (final params in <({bool consent, bool direct})>[
      (consent: false, direct: true),
      (consent: true, direct: false),
      (consent: false, direct: false),
    ]) {
      expect(
        await capture.proposeNaturalUserCarColorCorrectionCandidate(
          userPrompt: 'Ho riverniciato la mia auto: ora è rossa',
          consentEnabled: params.consent,
          directUserMessage: params.direct,
        ),
        isFalse,
      );
    }
    expect(await capture.loadReviewableNaturalCarColorCorrectionCandidates(),
        isEmpty);
    expect((await accepted()).single.content, 'La mia auto è blu');

    expect(
      await capture.proposeNaturalUserCarColorCorrectionCandidate(
        userPrompt: 'Ho riverniciato la mia auto: ora è rossa',
        consentEnabled: true,
        directUserMessage: true,
      ),
      isTrue,
    );
    final pending =
        (await capture.loadReviewableNaturalCarColorCorrectionCandidates())
            .single;
    expect(pending.before, 'La mia auto è blu');
    expect(pending.after, '100');
    expect(pending.status, AssistantMemoryStatus.candidate);
    expect((await accepted()).single.content, 'La mia auto è blu');

    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending,
      approve: false,
      userConfirmed: true,
    ), isTrue);
    expect((await accepted()).single.content, 'La mia auto è blu');
    expect(await capture.loadReviewableNaturalCarColorCorrectionCandidates(),
        isEmpty);
  });

  test('review replaces old color atomically and never retrieves stale color',
      () async {
    await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'Ho riverniciato la mia auto: ora è rossa',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableNaturalCarColorCorrectionCandidates())
            .single;
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending,
      approve: true,
    ), isFalse);
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending,
      approve: true,
      userConfirmed: true,
    ), isTrue);
    final current = await accepted();
    expect(current, hasLength(1));
    expect(current.single.content, 'La mia auto è rossa');
    expect(current.single.before, isNull);
    expect(current.single.source, AssistantMemorySource.userExplicit);
    expect(await capture.loadReviewableNaturalCarColorCorrectionCandidates(),
        isEmpty);
    for (final prompt in <String>[
      'Che colore è la mia auto?',
      'What color is my car?',
      'De quelle couleur est ma voiture ?',
      '¿De qué color es mi coche?',
    ]) {
      final context = await AssistantDurableMemoryContextService(
        memoryService: memory,
      ).buildConfirmedContext(sessionId: 'other-chat', userPrompt: prompt);
      expect(context, contains('La mia auto è rossa'), reason: prompt);
      expect(context, isNot(contains('La mia auto è blu')), reason: prompt);
    }
  });

  test('correction cannot recreate a deleted or concurrently changed fact',
      () async {
    await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'I repainted my car: it is now red',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableNaturalCarColorCorrectionCandidates())
            .single;
    final original = (await accepted()).single;
    expect(
      await memory.removeReviewedConfirmedUserMemory(reviewed: original),
      isTrue,
    );
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending, approve: true, userConfirmed: true,
    ), isFalse);
    expect(await accepted(), isEmpty);
    // Rejecting an obsolete proposal must still be possible.
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending, approve: false, userConfirmed: true,
    ), isTrue);

    await memory.recordConfirmed(
      recordKey: AssistantNaturalCarColorCandidate.recordKey,
      scope: AssistantMemoryScope.user,
      scopeId: userId,
      kind: AssistantMemoryKind.fact,
      content: 'My car is black',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 400,
    );
    expect(await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'I repainted my car: it is now white',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    final candidate =
        (await capture.loadReviewableNaturalCarColorCorrectionCandidates())
            .single;
    await memory.recordConfirmed(
      recordKey: AssistantNaturalCarColorCandidate.recordKey,
      scope: AssistantMemoryScope.user,
      scopeId: userId,
      kind: AssistantMemoryKind.fact,
      content: 'My car is green',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 401,
    );
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: candidate, approve: true, userConfirmed: true,
    ), isFalse);
    expect((await accepted()).single.content, 'My car is green');
  });

  test('incorrect review snapshot and invalid edits are never confirmed',
      () async {
    await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'Ho riverniciato la mia auto: ora è rossa',
      consentEnabled: true,
      directUserMessage: true,
    );
    final pending =
        (await capture.loadReviewableNaturalCarColorCorrectionCandidates())
            .single;
    for (final input in <String>[
      'La mia auto è rossa',
      'Ho cambiato auto: ora è PIN',
      'Ho riverniciato la mia auto: ora è rossa e blu',
      'My car is now 100',
    ]) {
      expect(await capture.reviewNaturalCarColorCorrectionCandidate(
        reviewed: pending,
        approve: true,
        userConfirmed: true,
        correctedContent: input,
      ), isFalse, reason: input);
    }
    await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'Ho riverniciato la mia auto: ora è nera',
      consentEnabled: true,
      directUserMessage: true,
    );
    expect(await capture.reviewNaturalCarColorCorrectionCandidate(
      reviewed: pending, approve: true, userConfirmed: true,
    ), isFalse);
    expect((await accepted()).single.content, 'La mia auto è blu');
  });
}
