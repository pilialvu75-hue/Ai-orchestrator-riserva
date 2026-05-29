import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RollingContextBuilder', () {
    test('keeps recalled lines separate from structured conversation turns', () {
      const builder = RollingContextBuilder(
        windowManager: MemoryWindowManager(
          maxContextLines: 8,
          maxTotalChars: 1000,
          minContextChars: 100,
        ),
      );

      final result = builder.build(
        messages: const <ChatMessage>[
          ChatMessage(
            id: 'm1',
            sessionId: 's1',
            role: 'user',
            content: 'Ask about trees',
            timestamp: 1,
          ),
          ChatMessage(
            id: 'm2',
            sessionId: 's1',
            role: 'assistant',
            content: 'Trees are connected acyclic graphs.',
            timestamp: 2,
          ),
          ChatMessage(
            id: 'm3',
            sessionId: 's1',
            role: 'user',
            content: 'Ask about arrays',
            timestamp: 3,
          ),
        ],
        userPrompt: 'Explain arrays instead.',
        excludedMessageId: 'm3',
        recalledContext: const <String>[
          'assistant: Earlier we discussed graph traversals.',
        ],
      );

      expect(
        result.recalledLines,
        equals(const <String>['assistant: Earlier we discussed graph traversals.']),
      );
      expect(
        result.contextTurns.map((turn) => '${turn.role}: ${turn.content}').toList(),
        equals(const <String>[
          'user: Ask about trees',
          'assistant: Trees are connected acyclic graphs.',
        ]),
      );
      expect(
        result.contextLines,
        equals(const <String>[
          'assistant: Earlier we discussed graph traversals.',
          'user: Ask about trees',
          'assistant: Trees are connected acyclic graphs.',
        ]),
      );
    });
  });
}
