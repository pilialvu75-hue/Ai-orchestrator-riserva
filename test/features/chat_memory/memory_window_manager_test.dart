import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryWindowManager', () {
    test('returns an isolated context snapshot', () {
      final source = <String>[
        'system: alpha',
        'user: beta',
        'assistant: gamma',
      ];

      final result = const MemoryWindowManager().trimToWindow(
        systemPrompt: 'stay focused',
        userPrompt: 'question',
        contextLines: source,
      );

      source[0] = 'system: changed';

      expect(result.contextLines, <String>[
        'system: alpha',
        'user: beta',
        'assistant: gamma',
      ]);
      expect(() => result.contextLines.add('delta'), throwsUnsupportedError);
    });
  });
}
