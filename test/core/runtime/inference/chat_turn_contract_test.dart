import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart' as core;
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart' as legacy;

void main() {
  test('legacy chat-memory path re-exports the canonical core contract', () {
    const legacyTurn = legacy.ChatTurn(
      role: legacy.ChatRole.user,
      content: 'hello',
    );

    expect(legacyTurn, isA<core.ChatTurn>());
    expect(legacyTurn.role, core.ChatRole.user);
  });

  test('InferenceRequest accepts the canonical core ChatTurn directly', () {
    const turn = core.ChatTurn(
      role: core.ChatRole.assistant,
      content: 'previous answer',
    );

    const request = InferenceRequest(
      sessionId: 'contract-test',
      prompt: 'next question',
      context: <core.ChatTurn>[turn],
    );

    expect(request.context, const <core.ChatTurn>[turn]);
    expect(request.toMessageList(), <Map<String, String>>[
      <String, String>{
        'role': 'assistant',
        'content': 'previous answer',
      },
      <String, String>{
        'role': 'user',
        'content': 'next question',
      },
    ]);
  });
}
