import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const normalizer = ChatTurnNormalizer();

  group('ChatTurnNormalizer', () {
    test('parses legacy role prefixes', () {
      final turn = normalizer.fromLegacyText('assistant: hello');
      expect(turn, const ChatTurn(role: ChatRole.assistant, content: 'hello'));
    });

    test('removes malformed repeated role prefixes', () {
      final turn = normalizer.fromLegacyText('userassistant: hello');
      expect(turn.role, ChatRole.user);
      expect(turn.content, 'hello');
    });

    test('normalizes structured turns without role text leakage', () {
      final turn = normalizer.normalize(
        const ChatTurn(
          role: ChatRole.system,
          content: 'system: stay focused',
        ),
      );

      expect(turn, const ChatTurn(role: ChatRole.system, content: 'stay focused'));
    });
  });
}
