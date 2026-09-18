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
  test('ordinary Phi prompt keeps latency-friendly automatic history', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.automatic(
          modelId: 'phi3_5_mini',
          isWeb: false,
        ),
      ),
    );

    final messages = List<ChatMessage>.generate(
      40,
      (index) => ChatMessage(
        id: 'm$index',
        sessionId: 's',
        role: index.isEven ? 'user' : 'assistant',
        content: 'turn-$index',
        timestamp: index,
      ),
    );

    final result = builder.build(
      messages: messages,
      userPrompt: 'Spiegami meglio questo punto.',
      systemPrompt: 'system',
    );

    expect(result.contextTurns, hasLength(24));
    expect(result.contextTurns.first.content, 'turn-16');
    expect(result.contextTurns.last.content, 'turn-39');
  });

  test('explicit continuity cue expands Phi chronology before runtime budget', () {
    final builder = RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.automatic(
          modelId: 'phi3_5_mini',
          isWeb: false,
        ),
      ),
    );

    final messages = List<ChatMessage>.generate(
      40,
      (index) => ChatMessage(
        id: 'm$index',
        sessionId: 's',
        role: index.isEven ? 'user' : 'assistant',
        content: 'turn-$index',
        timestamp: index,
      ),
    );

    final result = builder.build(
      messages: messages,
      userPrompt: 'Fai come abbiamo deciso nella conversazione precedente.',
      systemPrompt: 'system',
    );

    expect(result.contextTurns, hasLength(40));
    expect(result.contextTurns.first.content, 'turn-0');
    expect(result.contextTurns.last.content, 'turn-39');
  });

}
