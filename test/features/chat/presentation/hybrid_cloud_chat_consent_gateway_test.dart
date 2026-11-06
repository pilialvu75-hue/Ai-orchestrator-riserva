import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/features/chat/presentation/services/hybrid_cloud_chat_consent_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const question = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.unknown,
  );
  const memory = HybridDisclosureScope(
    HybridDisclosureOrigin.durableMemory,
    HybridDisclosureSensitivity.unknown,
  );
  final disclosure = HybridCloudDisclosure(
    ownerId: 'owner-a',
    // This is an install-local permission session, NOT the visible chat ID.
    sessionId: 'device-permission-session',
    providerId: 'gemini',
    accountId: 'account-a',
    purpose: 'Answer using selected confirmed memories',
    segments: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Current question', scope: question),
      HybridDisclosureSegment(text: '\nConfirmed private memory', scope: memory),
    ],
    outboundText: 'Current question\nConfirmed private memory',
  );
  final review = HybridCloudConsentReview(
    disclosure: disclosure,
    needsConsent: const <HybridDisclosureScope>[question, memory],
  );
  final gateway = HybridCloudChatConsentGateway.instance;

  Widget app(void Function(BuildContext) onContext) => MaterialApp(
    locale: const Locale('it'),
    supportedLocales: const <Locale>[
      Locale('it'), Locale('fr'), Locale('en'), Locale('es'),
    ],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Scaffold(body: Builder(
      builder: (context) {
        onContext(context);
        return const Center(child: Text('Active Aivexus Chat'));
      },
    )),
  );

  setUp(() => gateway.invalidate());
  tearDown(() => gateway.invalidate());

  testWidgets('no active Chat host or wrong chat ID: no dialog or approval',
      (tester) async {
    final absent = await gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => true,
    );
    expect(absent, isEmpty);
    BuildContext? context;
    await tester.pumpWidget(app((value) => context = value));
    await tester.pumpAndSettle();
    var currentChat = 'chat-a';
    final binding = gateway.bind(
      context: context!,
      activeSessionId: () => currentChat,
      isSending: () => true,
    );
    final wrong = await gateway.ask(
      chatSessionId: 'device-permission-session',
      review: review, isRequestActive: () => true,
    );
    expect(wrong, isEmpty);
    expect(find.byKey(const Key('review-apply')), findsNothing);
    currentChat = 'chat-b';
    final stale = await gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => true,
    );
    expect(stale, isEmpty);
    gateway.unbind(binding);
  });

  testWidgets('valid dialog returns ONLY choices for visible Chat session',
      (tester) async {
    BuildContext? context;
    await tester.pumpWidget(app((value) => context = value));
    await tester.pumpAndSettle();
    var sending = true;
    final binding = gateway.bind(
      context: context!,
      activeSessionId: () => 'chat-a',
      isSending: () => sending,
    );
    final response = gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-choice-currentQuestion-unknown')),
        findsOneWidget);
    expect(find.byKey(const Key('review-choice-durableMemory-unknown')),
        findsOneWidget);
    final questionChoice = tester.widget<
        DropdownButtonFormField<HybridCloudConsentChoice>>(
          find.byKey(const Key('review-choice-currentQuestion-unknown')),
        );
    questionChoice.onChanged?.call(HybridCloudConsentChoice.allowOnce);
    final memoryChoice = tester.widget<
        DropdownButtonFormField<HybridCloudConsentChoice>>(
          find.byKey(const Key('review-choice-durableMemory-unknown')),
        );
    memoryChoice.onChanged?.call(HybridCloudConsentChoice.allowOnce);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('review-apply')));
    await tester.tap(find.byKey(const Key('review-apply')));
    await tester.pumpAndSettle();
    final result = await response;
    expect(result[question], HybridCloudConsentChoice.allowOnce);
    expect(result[memory], HybridCloudConsentChoice.allowOnce);
    sending = false;
    gateway.unbind(binding);
  });

  testWidgets('changing visible conversation removes exact review route',
      (tester) async {
    BuildContext? context;
    await tester.pumpWidget(app((value) => context = value));
    await tester.pumpAndSettle();
    var activeId = 'chat-a';
    final binding = gateway.bind(
      context: context!,
      activeSessionId: () => activeId,
      isSending: () => true,
    );
    final response = gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-apply')), findsOneWidget);
    activeId = 'chat-b';
    gateway.invalidate(); // ChatPage._selectChat
    await tester.pumpAndSettle();
    expect(await response, isEmpty);
    expect(find.byKey(const Key('review-apply')), findsNothing);
    expect(find.text('Active Aivexus Chat'), findsOneWidget);
    gateway.unbind(binding);
  });

  testWidgets('cancelled request or ended send cannot approve even after tap',
      (tester) async {
    BuildContext? context;
    await tester.pumpWidget(app((value) => context = value));
    await tester.pumpAndSettle();
    var active = true;
    var sending = true;
    final binding = gateway.bind(
      context: context!,
      activeSessionId: () => 'chat-a',
      isSending: () => sending,
    );
    final response = gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => active,
    );
    await tester.pumpAndSettle();
    active = false;
    sending = false;
    await tester.ensureVisible(find.byKey(const Key('review-apply')));
    await tester.tap(find.byKey(const Key('review-apply')));
    await tester.pumpAndSettle();
    expect(await response, isEmpty);
    gateway.unbind(binding);
  });

  testWidgets('closing old Chat and reopening does not revive prior consent',
      (tester) async {
    BuildContext? context;
    await tester.pumpWidget(app((value) => context = value));
    await tester.pumpAndSettle();
    final oldBinding = gateway.bind(
      context: context!,
      activeSessionId: () => 'chat-a',
      isSending: () => true,
    );
    final pending = gateway.ask(
      chatSessionId: 'chat-a', review: review,
      isRequestActive: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-apply')), findsOneWidget);
    gateway.unbind(oldBinding);
    await tester.pumpAndSettle();
    expect(await pending, isEmpty);
    final currentBinding = gateway.bind(
      context: context!,
      activeSessionId: () => 'chat-b',
      isSending: () => true,
    );
    gateway.unbind(oldBinding); // stale owner cannot detach current host
    final fresh = gateway.ask(
      chatSessionId: 'chat-b', review: review,
      isRequestActive: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-apply')), findsOneWidget);
    gateway.invalidate();
    await tester.pumpAndSettle();
    expect(await fresh, isEmpty);
    gateway.unbind(currentBinding);
  });
}
