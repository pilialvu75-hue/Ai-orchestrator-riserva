import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryWindowManager', () {
    test('returns an isolated context snapshot', () {
      final source = <ChatTurn>[
        const ChatTurn(role: ChatRole.system, content: 'alpha'),
        const ChatTurn(role: ChatRole.user, content: 'beta'),
        const ChatTurn(role: ChatRole.assistant, content: 'gamma'),
      ];

      // Risolto l'errore: raccordata l'istanza costante passando il CharacterLengthEstimator obbligatorio
      final result = const MemoryWindowManager(
        tokenEstimator: CharacterLengthEstimator(),
      ).trimToWindow(
        systemPrompt: 'stay focused',
        userPrompt: 'question',
        contextTurns: source,
      );

      source[0] = const ChatTurn(role: ChatRole.system, content: 'changed');

      expect(result.contextTurns, <ChatTurn>[
        const ChatTurn(role: ChatRole.system, content: 'alpha'),
        const ChatTurn(role: ChatRole.user, content: 'beta'),
        const ChatTurn(role: ChatRole.assistant, content: 'gamma'),
      ]);
      expect(() => result.contextTurns.add(
        const ChatTurn(role: ChatRole.user, content: 'delta'),
      ), throwsUnsupportedError);
    });
  });
}
