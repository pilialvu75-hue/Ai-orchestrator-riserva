import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RollingContextBuilder', () {
    test('retains recalled context after chronological turns', () {
      final builder = RollingContextBuilder(
        windowManager: MemoryWindowManager(
          tokenEstimator: const CharacterLengthEstimator(),
          configProvider: () => MemoryWindowConfig.standard(isWeb: false),
        ),
      );

      final result = builder.build(
        messages: const [
          ChatMessage(
            id: '1',
            sessionId: 's',
            role: 'user',
            content: 'alpha',
            timestamp: 1,
          ),
          ChatMessage(
            id: '2',
            sessionId: 's',
            role: 'assistant',
            content: 'beta',
            timestamp: 2,
          ),
        ],
        userPrompt: 'gamma',
        recalledContext: const [
          ChatTurn(role: ChatRole.assistant, content: 'omega'),
        ],
      );

      expect(
        result.contextTurns,
        const [
          ChatTurn(role: ChatRole.user, content: 'alpha'),
          ChatTurn(role: ChatRole.assistant, content: 'beta'),
          ChatTurn(role: ChatRole.assistant, content: 'omega'),
        ],
      );
    });
  });
}
