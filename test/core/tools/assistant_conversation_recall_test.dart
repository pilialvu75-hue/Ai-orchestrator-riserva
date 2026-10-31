import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_conversation_recall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recalls user name across intervening turns without trusting assistant guesses', () {
    const history = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'ciao, io sono Aurora'),
      ChatTurn(role: ChatRole.assistant, content: 'Ti chiami Bruna.'),
      ChatTurn(role: ChatRole.user, content: 'Parliamo di computer.'),
    ];
    expect(
      AssistantConversationRecall.answer('quale è il mio nome?', history),
      'Ti chiami Aurora.',
    );
    expect(
      AssistantConversationRecall.answer("Qual'é il mio nome?", history),
      'Ti chiami Aurora.',
    );
    expect(
      AssistantConversationRecall.answer('Mi ricordi i presidenti?', history),
      isNull,
    );
    expect(
      AssistantConversationRecall.answer('Come mi chiamo?', history.sublist(1)),
      isNull,
    );
    expect(
      AssistantConversationRecall.answer('Come mi chiamo?', <ChatTurn>[
        ...history,
        const ChatTurn(role: ChatRole.user, content: 'Mi chiamo Carla.'),
      ]),
      'Ti chiami Carla.',
    );
    expect(
      AssistantConversationRecall.answer('Come mi chiamo?', const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'io sono stanco'),
      ]),
      isNull,
    );
    expect(
      AssistantConversationRecall.answer('Come mi chiamo?', const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'Non mi chiamo Aurora.'),
      ]),
      isNull,
    );
  });

  test('reproduces Android Giuseppe LOCAL screenshot without an LLM', () {
    const history = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'ciao sono Giuseppe'),
      ChatTurn(role: ChatRole.assistant, content: 'ciao Giuseppe'),
      ChatTurn(role: ChatRole.user, content: 'ho 16 anni e sono alto 1 metro e 20 centimetri'),
    ];
    expect(
      AssistantConversationRecall.answer('come mi chiamo ?', history),
      'Ti chiami Giuseppe.',
    );
    expect(
      AssistantConversationRecall.answer("Comment je m'appelle ?", history),
      "Tu t'appelles Giuseppe.",
    );
  });

  test('reproduces French friend recall and Italian language switch', () {
    const history = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'mon pote est Jérôme'),
      ChatTurn(
        role: ChatRole.assistant,
        content: "Je vois que votre ami s'appelle Jérôme.",
      ),
    ];
    expect(
      AssistantConversationRecall.answer("comment s'appelle mon pote?", history),
      "Ton ami s'appelle Jérôme.",
    );
    expect(
      AssistantConversationRecall.answer('come si chiama il mio amico?', history),
      'Il tuo amico si chiama Jérôme.',
    );
    expect(
      AssistantConversationRecall.answer('come mi chiamo?', history),
      isNull,
    );
    expect(
      AssistantConversationRecall.answer("comment s'appelle mon pote?", const <ChatTurn>[
        ChatTurn(
          role: ChatRole.assistant,
          content: "Je vois que votre ami s'appelle Jérôme.",
        ),
      ]),
      isNull,
    );
  });
}
