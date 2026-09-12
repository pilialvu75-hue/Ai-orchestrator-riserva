import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rolling context defers model-capacity trimming to the runtime', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 16,
          maxTotalSize: 512,
          isWeb: false,
        ),
      ),
    );

    final longUser = 'u' * 300;
    final longAssistant = 'a' * 300;
    final result = builder.build(
      messages: <ChatMessage>[
        ChatMessage(
          id: 'u1',
          sessionId: 's',
          role: 'user',
          content: longUser,
          timestamp: 1,
        ),
        ChatMessage(
          id: 'a1',
          sessionId: 's',
          role: 'assistant',
          content: longAssistant,
          timestamp: 2,
        ),
        const ChatMessage(
          id: 'u2',
          sessionId: 's',
          role: 'user',
          content: 'latest question',
          timestamp: 3,
        ),
      ],
      userPrompt: 'current prompt',
      systemPrompt: 'system',
    );

    expect(result.contextTurns, hasLength(3));
    expect(result.contextTurns.first.role, ChatRole.user);
    expect(result.contextTurns.first.content, longUser);
    expect(result.contextTurns[1].content, longAssistant);
    expect(result.contextTurns.last.content, 'latest question');
    expect(result.overflowDetected, isFalse);
    expect(result.totalChars, greaterThan(512));
  });
}
