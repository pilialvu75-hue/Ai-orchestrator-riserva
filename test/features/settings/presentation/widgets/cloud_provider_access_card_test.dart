import 'package:ai_orchestrator/features/settings/presentation/cloud_provider_access_summary.dart';
import 'package:ai_orchestrator/features/settings/presentation/widgets/cloud_provider_access_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders provider-neutral Cloud access classification', (tester) async {
    final groq = CloudProviderAccessSummary.forProvider('groq')!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudProviderAccessCard(summary: groq),
        ),
      ),
    );

    expect(
      find.byKey(const Key('cloud_provider_access_summary')),
      findsOneWidget,
    );
    expect(find.text('Account-dependent free access'), findsOneWidget);
    expect(find.text(groq.description), findsOneWidget);

    final openRouter = CloudProviderAccessSummary.forProvider('openRouter')!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudProviderAccessCard(summary: openRouter),
        ),
      ),
    );

    expect(find.text('Recurring free tier'), findsOneWidget);
    expect(find.text(openRouter.description), findsOneWidget);
  });
}
