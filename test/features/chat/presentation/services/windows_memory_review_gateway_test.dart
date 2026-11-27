import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_memory_review.dart';
import 'package:ai_orchestrator/features/chat/presentation/services/windows_memory_review_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const review = WindowsMemoryReview(modelBytes: 9 * 1073741824,
      availableRamBytes: 5 * 1073741824, availableVramBytes: 8 * 1073741824,
      canAttempt: true);

  testWidgets('explicit attempt returns choice for active session only', (tester) async {
    final gateway = WindowsMemoryReviewGateway();
    late Object host;
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      context = ctx;
      return const Scaffold(body: Text('Chat'));
    })));
    host = gateway.bind(context: context, activeSessionId: () => 'chat-a',
        isSending: () => true);
    addTearDown(() => gateway.unbind(host));
    expect(await gateway.ask('chat-b', review, CancellationToken()), WindowsMemoryChoice.cancel);
    final answer = gateway.ask('chat-a', review, CancellationToken());
    await tester.pumpAndSettle();
    expect(find.text('Potentially insufficient memory'), findsOneWidget);
    expect(find.text('Model file: 9.00 GiB'), findsOneWidget);
    await tester.tap(find.text('Try anyway'));
    await tester.pumpAndSettle();
    expect(await answer, WindowsMemoryChoice.tryAnyway);
    expect(find.text('Potentially insufficient memory'), findsNothing);
  });

  testWidgets('unverified plan cannot be approved and cancellation removes exact dialog', (tester) async {
    final gateway = WindowsMemoryReviewGateway();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      context = ctx;
      return const Scaffold(body: Text('Chat'));
    })));
    final host = gateway.bind(context: context, activeSessionId: () => 'chat-a',
        isSending: () => true);
    addTearDown(() => gateway.unbind(host));
    final cancellation = CancellationToken();
    final pending = gateway.ask('chat-a',
        const WindowsMemoryReview(modelBytes: 99, canAttempt: false), cancellation);
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Try anyway'));
    expect(button.onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Reduced settings')).onPressed, isNull);
    cancellation.cancel();
    await tester.pumpAndSettle();
    expect(await pending, WindowsMemoryChoice.cancel);
    expect(find.text('Chat'), findsOneWidget);
  });
}
