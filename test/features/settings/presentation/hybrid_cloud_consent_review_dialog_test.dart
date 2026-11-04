import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/features/settings/presentation/widgets/hybrid_cloud_consent_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const question = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.personal,
  );
  const memory = HybridDisclosureScope(
    HybridDisclosureOrigin.durableMemory,
    HybridDisclosureSensitivity.confidential,
  );

  final data = HybridCloudDisclosure(
    ownerId: 'owner-a',
    sessionId: 'chat-a',
    providerId: 'gemini',
    accountId: 'account-a',
    purpose: 'Answer with selected memories',
    segments: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(
        text: 'Current question containing private details.',
        scope: question,
      ),
      HybridDisclosureSegment(
        text: '\nConfidential remembered context.',
        scope: memory,
      ),
    ],
    outboundText: 'Current question containing private details.'
        '\nConfidential remembered context.',
  );
  final review = HybridCloudConsentReview(
    disclosure: data,
    needsConsent: const <HybridDisclosureScope>[question, memory],
  );

  Widget app(void Function(BuildContext) show) => MaterialApp(
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
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => show(context),
              child: const Text('Open review'),
            ),
          ),
        )),
      );

  testWidgets('review shows provider account and each exact information scope',
      (tester) async {
    Map<HybridDisclosureScope, HybridCloudConsentChoice>? answer;
    await tester.pumpWidget(app((context) {
      HybridCloudConsentReviewDialog.ask(context, review)
          .then((value) => answer = value);
    }));
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('gemini'), findsOneWidget);
    expect(find.textContaining('account-a'), findsOneWidget);
    expect(find.byKey(const Key('review-choice-currentQuestion-personal')),
        findsOneWidget);
    expect(find.byKey(const Key('review-choice-durableMemory-confidential')),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('review-section-1')));
    await tester.tap(find.byKey(const Key('review-section-1')));
    await tester.pumpAndSettle();
    expect(find.text('Confidential remembered context.'), findsNothing);
    expect(find.textContaining('Confidential remembered context.'),
        findsWidgets);
    await tester.tap(find.byKey(const Key('review-cancel')));
    await tester.pumpAndSettle();
    expect(answer, isEmpty);
  });

  testWidgets('default choices DENY both categories, never auto allow',
      (tester) async {
    Map<HybridDisclosureScope, HybridCloudConsentChoice>? answer;
    await tester.pumpWidget(app((context) {
      HybridCloudConsentReviewDialog.ask(context, review)
          .then((value) => answer = value);
    }));
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('review-apply')));
    await tester.tap(find.byKey(const Key('review-apply')));
    await tester.pumpAndSettle();
    expect(answer, hasLength(2));
    expect(answer![question], HybridCloudConsentChoice.denyOnce);
    expect(answer![memory], HybridCloudConsentChoice.denyOnce);
  });

  testWidgets('dismiss without applying returns NO approvals', (tester) async {
    Map<HybridDisclosureScope, HybridCloudConsentChoice>? answer;
    await tester.pumpWidget(app((context) {
      HybridCloudConsentReviewDialog.ask(context, review)
          .then((value) => answer = value);
    }));
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-cancel')));
    await tester.pumpAndSettle();
    expect(answer, isEmpty);
  });
}
