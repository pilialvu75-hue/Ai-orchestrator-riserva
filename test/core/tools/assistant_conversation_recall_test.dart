import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_conversation_recall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recalls user name across intervening turns without trusting assistant guesses', () {
    const history = [ChatTurn(role: ChatRole.user, content: 'ciao, io sono Aurora'),
      ChatTurn(role: ChatRole.assistant, content: 'Ti chiami Bruna.'),
      ChatTurn(role: ChatRole.user, content: 'Parliamo di computer.')];
    expect(AssistantConversationRecall.answer('quale è il mio nome?', history), 'Ti chiami Aurora.');
    expect(AssistantConversationRecall.answer("Qual'é il mio nome?", history), 'Ti chiami Aurora.');
    expect(AssistantConversationRecall.answer('Mi ricordi i presidenti?', history), isNull);
    expect(AssistantConversationRecall.answer('Come mi chiamo?', history.sublist(1)), isNull);
    expect(AssistantConversationRecall.answer('Come mi chiamo?', [...history,
      const ChatTurn(role: ChatRole.user, content: 'Mi chiamo Carla.')]), 'Ti chiami Carla.');
    expect(AssistantConversationRecall.answer('Come mi chiamo?', [
      const ChatTurn(role: ChatRole.user, content: 'io sono stanco')]), isNull);
    expect(AssistantConversationRecall.answer('Come mi chiamo?', [
      const ChatTurn(role: ChatRole.user, content: 'Non mi chiamo Aurora.')]), isNull);
  });
}
