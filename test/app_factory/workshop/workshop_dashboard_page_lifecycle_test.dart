import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  testWidgets('injected Workshop chat survives route disposal', (tester) async {
    final provider = _CapturingProvider();
    final chat = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
      sessionId: 'route-stable-chat',
    );
    addTearDown(chat.dispose);

    chat.addSystemMessage('turno persistente');

    await tester.pumpWidget(
      MaterialApp(
        home: WorkshopDashboardPage(
          chatController: chat,
        ),
      ),
    );
    await tester.pump();

    expect(
      chat.messages.any((turn) => turn.content == 'turno persistente'),
      isTrue,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(
      chat.messages.any((turn) => turn.content == 'turno persistente'),
      isTrue,
    );

    chat.addSystemMessage('dopo il detach');
    expect(
      chat.messages.any((turn) => turn.content == 'dopo il detach'),
      isTrue,
    );
  });

  testWidgets('approving a proposal does not trigger a second chat inference',
      (tester) async {
    final provider = _CapturingProvider();
    final chat = WorkshopChatController(
      inferenceGateway: WorkshopInferenceGateway(provider: provider),
      sessionId: 'approval-single-inference',
    );
    final dashboard = WorkshopDashboardController(
      engine: WorkshopEngine(),
    );
    addTearDown(chat.dispose);
    addTearDown(dashboard.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: WorkshopDashboardPage(
          chatController: chat,
          dashboardController: dashboard,
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byType(TextField),
      'Crea una semplice app contatore con +, - e reset.',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(provider.requests, hasLength(1));
    expect(find.text('Sì, procedi'), findsOneWidget);

    await tester.tap(find.text('Sì, procedi'));
    await tester.pumpAndSettle();

    expect(provider.requests, hasLength(1));
    expect(
      chat.messages.where((turn) => turn.role == ChatRole.user),
      hasLength(1),
    );
    expect(
      chat.messages.any(
        (turn) =>
            turn.role == ChatRole.system &&
            turn.content.contains('Proposta approvata'),
      ),
      isTrue,
    );
  });
}

final class _CapturingProvider implements RuntimeInferenceProvider {
  final List<InferenceRequest> requests = <InferenceRequest>[];

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    requests.add(request);

    yield InferenceResponse.finalChunk(
      text: 'Proposta pronta per approvazione.',
      tokensGenerated: 4,
      model: 'fake-workshop',
    );
  }
}
