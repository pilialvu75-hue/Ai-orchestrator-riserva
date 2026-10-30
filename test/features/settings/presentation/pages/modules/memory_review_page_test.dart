import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_store.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/memory_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Persistence implements AssistantDurableMemoryPersistence {
  final Map<String, String> rows = <String, String>{};
  @override
  Future<String?> read(String key) async => rows[key];

  @override
  Future<void> write(String key, String value) async {
    rows[key] = value;
  }
}

void main() {
  late AssistantDurableMemoryService memory;
  late AssistantDurableMemoryCaptureService capture;
  const scopeId = AssistantDurableMemoryContextService.localUserScopeId;

  setUp(() {
    memory = AssistantDurableMemoryService(
      store: AssistantDurableMemoryStore(persistence: _Persistence()),
    );
    capture = AssistantDurableMemoryCaptureService(
      memoryService: memory,
      now: () => 1000,
    );
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: MemoryReviewPage(captureService: capture)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> propose(String text) async {
    expect(
      await capture.proposeUserPreferenceCandidate(
        userPrompt: text,
        consentEnabled: true,
      ),
      isTrue,
    );
  }

  testWidgets('empty page explains that automatic capture remains disabled',
      (tester) async {
    await mount(tester);
    expect(find.text('Nessuna proposta da controllare'), findsOneWidget);
    expect(find.textContaining('La raccolta automatica non è attiva'),
        findsOneWidget);
    expect(find.text('Approva'), findsNothing);
  });

  testWidgets('approval requires a second explicit confirmation',
      (tester) async {
    await propose('Preferisco risposte brevi');
    await mount(tester);
    expect(find.text('Preferisco risposte brevi'), findsOneWidget);
    await tester.tap(find.text('Approva'));
    await tester.pumpAndSettle();
    expect(find.text('Confermare il ricordo?'), findsOneWidget);

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(
      await memory.loadConfirmed(
        scope: AssistantMemoryScope.user,
        scopeId: scopeId,
      ),
      isEmpty,
    );

    await tester.tap(find.text('Approva').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approva').last);
    await tester.pumpAndSettle();
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    );
    expect(confirmed.single.content, 'Preferisco risposte brevi');
    expect(find.text('Nessuna proposta da controllare'), findsOneWidget);
  });

  testWidgets('correction validates and replaces only the reviewed preference',
      (tester) async {
    await propose('Preferisco risposte brevi');
    await mount(tester);
    await tester.tap(find.text('Correggi'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory-review-edit-field')),
      'Preferisco risposte dettagliate',
    );
    await tester.tap(find.text('Conferma correzione'));
    await tester.pumpAndSettle();
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    );
    expect(confirmed.single.content, 'Preferisco risposte dettagliate');
    expect(find.text('Nessuna proposta da controllare'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejection removes just the candidate and not accepted facts',
      (tester) async {
    await memory.recordConfirmed(
      recordKey: 'unrelated',
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
      kind: AssistantMemoryKind.fact,
      content: 'Un fatto già confermato',
      source: AssistantMemorySource.userExplicit,
      updatedAt: 50,
    );
    await propose('Preferisco risposte brevi');
    await mount(tester);
    await tester.tap(find.text('Scarta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarta').last);
    await tester.pumpAndSettle();

    expect(
      await capture.loadReviewablePreferenceCandidates(),
      isEmpty,
    );
    final confirmed = await memory.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: scopeId,
    );
    expect(confirmed.single.content, 'Un fatto già confermato');
    expect(find.text('Nessuna proposta da controllare'), findsOneWidget);
  });
}
