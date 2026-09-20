import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/inference/conversation_context_limits.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chronological recall prepends complete non-duplicated exchanges', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 2,
          maxTotalSize: 10000,
          isWeb: false,
        ),
      ),
    );

    final result = builder.build(
      messages: const <ChatMessage>[
        ChatMessage(
          id: 'u1',
          sessionId: 's',
          role: 'user',
          content: 'recent question',
          timestamp: 3,
        ),
        ChatMessage(
          id: 'a1',
          sessionId: 's',
          role: 'assistant',
          content: 'recent answer',
          timestamp: 4,
        ),
      ],
      userPrompt: 'continua',
      recalledContext: const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'older question'),
        ChatTurn(role: ChatRole.assistant, content: 'older answer'),
        // This duplicate pair must be discarded as a whole.
        ChatTurn(role: ChatRole.user, content: 'recent question'),
        ChatTurn(role: ChatRole.assistant, content: 'recent answer'),
      ],
    );

    expect(
      result.contextTurns,
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'older question'),
        ChatTurn(role: ChatRole.assistant, content: 'older answer'),
        ChatTurn(role: ChatRole.user, content: 'recent question'),
        ChatTurn(role: ChatRole.assistant, content: 'recent answer'),
      ],
    );
  });

  test('incomplete recalled user turn is never injected alone', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 2,
          maxTotalSize: 10000,
          isWeb: false,
        ),
      ),
    );

    final result = builder.build(
      messages: const <ChatMessage>[
        ChatMessage(
          id: 'u1',
          sessionId: 's',
          role: 'user',
          content: 'recent question',
          timestamp: 3,
        ),
        ChatMessage(
          id: 'a1',
          sessionId: 's',
          role: 'assistant',
          content: 'recent answer',
          timestamp: 4,
        ),
      ],
      userPrompt: 'continua',
      recalledContext: const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'orphan old question'),
      ],
    );

    expect(
      result.contextTurns,
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'recent question'),
        ChatTurn(role: ChatRole.assistant, content: 'recent answer'),
      ],
    );
  });

  test('recalled bundle stays within the portable cross-runtime envelope', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.custom(
          maxContextLines: 40,
          maxTotalSize: 100000,
          isWeb: false,
        ),
      ),
    );

    final messages = List<ChatMessage>.generate(30, (index) {
      final user = index.isEven;
      return ChatMessage(
        id: 'm$index',
        sessionId: 's',
        role: user ? 'user' : 'assistant',
        content: '${user ? 'recent-question' : 'recent-answer'}-$index',
        timestamp: index + 1,
      );
    });

    final result = builder.build(
      messages: messages,
      userPrompt: 'continua',
      recalledContext: const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'older-question-1'),
        ChatTurn(role: ChatRole.assistant, content: 'older-answer-1'),
        ChatTurn(role: ChatRole.user, content: 'older-question-2'),
        ChatTurn(role: ChatRole.assistant, content: 'older-answer-2'),
      ],
    );

    expect(
      result.contextTurns.length,
      lessThanOrEqualTo(ConversationContextLimits.safeCrossRuntimeTurns),
    );
    expect(
      result.contextTurns.take(4),
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'older-question-1'),
        ChatTurn(role: ChatRole.assistant, content: 'older-answer-1'),
        ChatTurn(role: ChatRole.user, content: 'older-question-2'),
        ChatTurn(role: ChatRole.assistant, content: 'older-answer-2'),
      ],
    );
    expect(result.contextTurns[4].role, ChatRole.user);
    expect(result.contextTurns.last.content, 'recent-answer-29');
  });

}
