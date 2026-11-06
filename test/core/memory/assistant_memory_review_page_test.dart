import 'dart:async';

import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_natural_memory_consent_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/assistant_memory_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';

class _MemoryPersistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _PendingReadPersistence implements AssistantDurableMemoryPersistence {
  final readResult = Completer<String?>();
  @override
  Future<String?> read(String key) => readResult.future;
  @override
  Future<void> write(String key, String value) async {}
}

void main() {
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;

  Future<void> showPage(WidgetTester tester, {String language = 'it'}) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('it'), Locale('en'), Locale('fr'), Locale('es')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: AssistantMemoryReviewPage(
        captureService: capture,
        consentService: AssistantNaturalMemoryConsentService(
          preferences: preferences,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // Construct queued Futures in the widget test's own FakeAsync zone.
  void initializeMemory({AssistantDurableMemoryPersistence? persistence}) {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: persistence ?? _MemoryPersistence(),
      ),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
    );
  }

  testWidgets('chat natural-memory opt-in is off, persisted and revocable',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    final preferences = await SharedPreferences.getInstance();
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(preferences.getBool(
      AssistantNaturalMemoryConsentService.preferenceKey,
    ), isNull);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.getBool(
      AssistantNaturalMemoryConsentService.preferenceKey,
    ), isTrue);
    await showPage(tester);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.getBool(
      AssistantNaturalMemoryConsentService.preferenceKey,
    ), isFalse);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
  });

  testWidgets('no proposal is written without per-action consent',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'Preferisco risposte brevi',
    );
    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Proponi per revisione'),
      ).onPressed,
      isNull,
    );
    expect(
      await memory.loadCandidates(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );
    // The new consent toggle makes this ListView longer; discover the
    // lazily built empty-state below the manual proposal controls.
    await tester.scrollUntilVisible(
      find.text('Nessuna proposta in attesa.'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Nessuna proposta in attesa.'), findsOneWidget);
  });

  testWidgets('explicit proposal and approval confirm local memory',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'Preferisco risposte brevi',
    );
    await tester.tap(find.text('Autorizzo questa singola proposta di prova'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Proponi per revisione'));
    await tester.tap(find.text('Proponi per revisione'));
    await tester.pumpAndSettle();

    // The single-action consent does not stay enabled.
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    final pending = await memory.loadCandidates(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(pending, hasLength(1));
    expect(pending.single.status, AssistantMemoryStatus.candidate);
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );

    await tester.ensureVisible(find.text('Approva'));
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    expect(find.text('Confermi il ricordo?'), findsOneWidget);
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    final accepted = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(accepted, hasLength(1));
    expect(accepted.single.content, 'Preferisco risposte brevi');
    expect(find.text('Nessuna proposta in attesa.'), findsOneWidget);
  });

  testWidgets('correction requires review and saves only approved text',
      (tester) async {
    initializeMemory();
    await capture.proposeUserPreferenceCandidate(
      userPrompt: 'Preferisco risposte brevi',
      consentEnabled: true,
    );
    await showPage(tester);
    await tester.scrollUntilVisible(
      find.text('Correggi'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Correggi'));
    await tester.tap(find.text('Correggi'));
    await tester.pumpAndSettle();
    expect(find.text('Correggi la proposta'), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField),
      'Preferisco le risposte dettagliate',
    );
    await tester.tap(find.text('Continua'));
    await tester.pumpAndSettle();
    expect(find.text('Confermi il ricordo?'), findsOneWidget);
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    final accepted = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(accepted.single.content, 'Preferisco le risposte dettagliate');
    expect(find.text('Nessuna proposta in attesa.'), findsOneWidget);
  });

  testWidgets('reject requires confirmation and preserves other facts',
      (tester) async {
    initializeMemory();
    await capture.proposeUserPreferenceCandidate(
      userPrompt: 'Preferisco risposte dettagliate',
      consentEnabled: true,
    );
    await memory.recordConfirmed(
      recordKey: 'existing',
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      kind: AssistantMemoryKind.fact,
      content: 'Ricordo già confermato',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 10,
    );
    await showPage(tester);
    await tester.scrollUntilVisible(
      find.text('Scarta'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Scarta'));
    await tester.tap(find.text('Scarta'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(
      await memory.loadCandidates(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      hasLength(1),
    );

    await tester.tap(find.text('Scarta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarta').last);
    await tester.pumpAndSettle();
    expect(
      await memory.loadCandidates(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );
    final accepted = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(accepted.single.content, 'Ricordo già confermato');
  });
  for (final language in ['it', 'en', 'fr', 'es']) {
    testWidgets('review labels and explicit Italian input in $language',
        (tester) async {
      initializeMemory();
      final strings = AppLocalizations(Locale(language));
      await showPage(tester, language: language);
      expect(find.text(strings.t('memory_review_title')), findsOneWidget);
      expect(find.text(strings.t('memory_review_italian_only')), findsOneWidget);
      final submit = find.widgetWithText(
        FilledButton, strings.t('memory_review_propose'),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first,
          'Preferisco risposte brevi');
      await tester.tap(find.text(strings.t('memory_review_consent')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(
          find.byType(CheckboxListTile)).value, isFalse);
      expect(await capture.loadReviewablePreferenceCandidates(), hasLength(1));
      expect(await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ), isEmpty);
      await tester.ensureVisible(find.text(strings.t('memory_review_approve')));
      await tester.tap(find.text(strings.t('memory_review_approve')));
      await tester.pumpAndSettle();
      expect(find.text(strings.t('memory_review_confirm_title')), findsOneWidget);
      await tester.tap(find.text(strings.t('memory_review_cancel')));
      await tester.pumpAndSettle();
      expect(await capture.loadReviewablePreferenceCandidates(), hasLength(1));
    });
  }

  testWidgets('late storage error after leaving review does not use disposed context',
      (tester) async {
    final persistence = _PendingReadPersistence();
    initializeMemory(persistence: persistence);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(MaterialApp(
      home: AssistantMemoryReviewPage(
        captureService: capture,
        consentService: AssistantNaturalMemoryConsentService(
          preferences: preferences,
        ),
      ),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    persistence.readResult.completeError(StateError('synthetic read failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });


  // Confirmed facts are below the manual proposal form in a lazy ListView.
  // A widget test's small viewport must scroll far enough to build each row.
  Future<void> revealConfirmed(WidgetTester tester, Finder textFinder) async {
    await tester.scrollUntilVisible(
      textFinder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(textFinder);
    await tester.pumpAndSettle();
  }

  testWidgets('confirmed memory needs consent to forget, others survive',
      (tester) async {
    initializeMemory();
    const id = AssistantDurableMemoryContextService.localUserScopeId;
    await memory.recordConfirmed(
      recordKey: 'budget',
      scope: AssistantMemoryScope.user,
      scopeId: id,
      kind: AssistantMemoryKind.fact,
      content: 'Il budget è 420',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 21,
    );
    await memory.recordConfirmed(
      recordKey: 'moto',
      scope: AssistantMemoryScope.user,
      scopeId: id,
      kind: AssistantMemoryKind.fact,
      content: 'La moto è rossa',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 22,
    );
    await showPage(tester);
    await revealConfirmed(tester, find.text('Il budget è 420'));
    expect(find.text('Il budget è 420'), findsOneWidget);
    final tile = find.ancestor(
      of: find.text('Il budget è 420'),
      matching: find.byType(ListTile),
    );
    final forgetBudget =
        find.descendant(of: tile, matching: find.text('Dimentica'));
    await tester.ensureVisible(forgetBudget);
    await tester.tap(forgetBudget);
    await tester.pumpAndSettle();
    expect(find.text('Dimenticare questo ricordo confermato?'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: id,
    ), hasLength(2));
    // Forget only budget by selecting the same reviewed tile.
    await revealConfirmed(tester, find.text('Il budget è 420'));
    await tester.ensureVisible(forgetBudget);
    await tester.tap(forgetBudget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dimentica').last);
    await tester.pumpAndSettle();
    final saved = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: id,
    );
    expect(saved.map((item) => item.recordKey), <String>['moto']);
    await revealConfirmed(tester, find.text('La moto è rossa'));
    expect(find.text('La moto è rossa'), findsOneWidget);
    expect(find.text('Il budget è 420'), findsNothing);
  });

  testWidgets('stale displayed fact cannot delete a newer correction',
      (tester) async {
    initializeMemory();
    const id = AssistantDurableMemoryContextService.localUserScopeId;
    await memory.recordConfirmed(
      recordKey: 'budget',
      scope: AssistantMemoryScope.user,
      scopeId: id,
      kind: AssistantMemoryKind.fact,
      content: 'Il budget è 420',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 21,
    );
    await showPage(tester);
    await memory.recordConfirmed(
      recordKey: 'budget',
      scope: AssistantMemoryScope.user,
      scopeId: id,
      kind: AssistantMemoryKind.fact,
      content: 'Il budget è 680',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 22,
    );
    await revealConfirmed(tester, find.text('Il budget è 420'));
    final tile = find.ancestor(
      of: find.text('Il budget è 420'),
      matching: find.byType(ListTile),
    );
    final forgetBudget =
        find.descendant(of: tile, matching: find.text('Dimentica'));
    await tester.ensureVisible(forgetBudget);
    await tester.tap(forgetBudget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dimentica').last);
    await tester.pumpAndSettle();
    expect((await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: id,
    )).single.content, 'Il budget è 680');
    await revealConfirmed(tester, find.text('Il budget è 680'));
    expect(find.text('Il budget è 680'), findsOneWidget);
  });



  testWidgets('natural first-name proposal follows review and remains local',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    await tester.enterText(
      find.byType(TextField).first,
      "Je m'appelle Annabelle",
    );
    // Unlike a silent chat listener, the preview requires a fresh
    // per-proposal consent that is reset after the stage operation.
    await tester.tap(find.text('Autorizzo questa singola proposta di prova'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Proponi per revisione'));
    await tester.tap(find.text('Proponi per revisione'));
    await tester.pumpAndSettle();

    expect((await capture.loadReviewableNaturalNameCandidates()), hasLength(1));
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );

    await tester.ensureVisible(find.text('Approva'));
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    final stored = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(stored, hasLength(1));
    expect(stored.single.content, "Je m'appelle Annabelle");
    expect(stored.single.source, AssistantMemorySource.userExplicit);
    expect(await capture.loadReviewableNaturalNameCandidates(), isEmpty);
  });


  testWidgets('car color manual proposal requires review to become a fact',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'La mia auto è blu',
    );
    await tester.tap(find.text('Autorizzo questa singola proposta di prova'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Proponi per revisione'));
    await tester.tap(find.text('Proponi per revisione'));
    await tester.pumpAndSettle();

    expect(
      (await capture.loadReviewableNaturalCarColorCandidates()).single.content,
      'La mia auto è blu',
    );
    expect(await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    ), isEmpty);

    await tester.scrollUntilVisible(
      find.text('Approva'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    final saved = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(saved, hasLength(1));
    expect(saved.single.content, 'La mia auto è blu');
    expect(saved.single.source, AssistantMemorySource.userExplicit);
    expect(await capture.loadReviewableNaturalCarColorCandidates(), isEmpty);
  });


  testWidgets('owner reviews car color change without losing old fact early',
      (tester) async {
    initializeMemory();
    const owner = AssistantDurableMemoryContextService.localUserScopeId;
    await memory.recordConfirmed(
      recordKey: 'natural.user.car_color',
      scope: AssistantMemoryScope.user,
      scopeId: owner,
      kind: AssistantMemoryKind.fact,
      content: 'La mia auto è blu',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 100,
    );
    expect(await capture.proposeNaturalUserCarColorCorrectionCandidate(
      userPrompt: 'Ho riverniciato la mia auto: ora è rossa',
      consentEnabled: true,
      directUserMessage: true,
    ), isTrue);
    expect((await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: owner,
    )).single.content, 'La mia auto è blu');

    await showPage(tester);
    await tester.scrollUntilVisible(
      find.text('Ho riverniciato la mia auto: ora è rossa'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    final proposal = find.ancestor(
      of: find.text('Ho riverniciato la mia auto: ora è rossa'),
      matching: find.byType(Card),
    );
    final approve = find.descendant(
      of: proposal,
      matching: find.text('Approva'),
    );
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    expect((await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: owner,
    )).single.content, 'La mia auto è rossa');
    expect(await capture.loadReviewableNaturalCarColorCorrectionCandidates(),
        isEmpty);
  });


  testWidgets('ME-2 named colleague needs single-action consent and UI review',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    await tester.enterText(find.byType(TextField).first, 'Jerome è alto');

    // The review page must not stage even a named fact without this action's
    // explicit owner consent. The persistent chat opt-in is a separate toggle.
    final propose = find.widgetWithText(
      FilledButton, 'Proponi per revisione',
    );
    expect(tester.widget<FilledButton>(propose).onPressed, isNull);
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);

    await tester.tap(find.text('Autorizzo questa singola proposta di prova'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(propose);
    await tester.tap(propose);
    await tester.pumpAndSettle();

    final pending =
        await capture.loadReviewableManualEntityReferenceCandidates();
    expect(pending, hasLength(1));
    expect(pending.single.content, 'Jerome è alto');
    expect(
      tester.widget<CheckboxListTile>(
        find.byType(CheckboxListTile),
      ).value,
      isFalse,
    );
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );

    await tester.scrollUntilVisible(
      find.text('Approva'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    expect(find.text('Confermi il ricordo?'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        hasLength(1));

    await tester.ensureVisible(find.text('Approva'));
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();

    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
    );
    expect(confirmed, hasLength(1));
    expect(confirmed.single.content, 'Jerome è alto');
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        isEmpty);

    final context = AssistantDurableMemoryContextService(
      memoryService: memory,
    );
    expect(
      await context.buildConfirmedContext(
        sessionId: 'second-chat',
        userPrompt: 'Jerome è alto?',
      ),
      contains('Jerome è alto'),
    );
    expect(
      await context.buildConfirmedContext(
        sessionId: 'second-chat',
        userPrompt: 'Kader è alto?',
      ),
      isNull,
    );
    expect(
      await context.buildConfirmedContext(
        sessionId: 'second-chat',
        userPrompt: 'Cosa sai di me?',
      ),
      isNull,
    );
  });

  testWidgets('ME-2 correction cannot silently rename Jerome as Kader',
      (tester) async {
    initializeMemory();
    expect(
      await capture.proposeManualEntityReferenceCandidate(
        userPrompt: 'Jerome è alto',
        consentEnabled: true,
        directUserMessage: true,
      ),
      isTrue,
    );
    await showPage(tester);
    await tester.scrollUntilVisible(
      find.text('Correggi'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Correggi'));
    await tester.pumpAndSettle();
    expect(find.text('Kader è alto'), findsNothing);
    await tester.enterText(find.byType(TextFormField), 'Kader è alto');
    await tester.tap(find.text('Continua'));
    await tester.pumpAndSettle();
    expect(find.text('Confermi il ricordo?'), findsOneWidget);
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      ),
      isEmpty,
    );
    expect(await capture.loadReviewableManualEntityReferenceCandidates(),
        hasLength(1));
  });

}
