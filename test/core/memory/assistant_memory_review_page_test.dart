import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/assistant_memory_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;

  Future<void> showPage(WidgetTester tester, {String language = 'it'}) async {
    await tester.pumpWidget(MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('it'), Locale('en'), Locale('fr'), Locale('es')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: AssistantMemoryReviewPage(captureService: capture),
    ));
    await tester.pumpAndSettle();
  }

  // Construct queued Futures in the widget test's own FakeAsync zone.
  void initializeMemory() {
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(
        persistence: _MemoryPersistence(),
      ),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
    );
  }

  testWidgets('no proposal is written without per-action consent',
      (tester) async {
    initializeMemory();
    await showPage(tester);
    expect(find.text('Nessuna proposta in attesa.'), findsOneWidget);
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

}
