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

  test('S24 colleague Mika: names, user description and follow-up topic', () {
    const history = <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'il nome del mio collega è Mika'),
      ChatTurn(role: ChatRole.assistant, content: 'Il tuo collega si chiama Mika.'),
      ChatTurn(role: ChatRole.user, content: 'ed è un idiota'),
      ChatTurn(role: ChatRole.assistant, content: 'Commento ricevuto.'),
      ChatTurn(role: ChatRole.user, content: 'come si chiama il mio collega?'),
      ChatTurn(role: ChatRole.assistant,
          content: 'Nessuna app riconosciuta nel comando.'),
      ChatTurn(role: ChatRole.user,
          content: 'quale e il nome del mio collega?'),
      ChatTurn(role: ChatRole.assistant,
          content: 'Il nome del tuo collega è Mika.'),
    ];
    expect(AssistantConversationRecall.answer('Come si chiama il mio collega?', history),
        'Il tuo collega si chiama Mika.');
    expect(AssistantConversationRecall.answer('e che cosa è?', history),
        'Hai detto che il tuo collega Mika è un idiota.');
    expect(AssistantConversationRecall.answer('e che cosa è Mika?', history),
        'Hai detto che il tuo collega Mika è un idiota.');
    expect(AssistantConversationRecall.answer('e che cosa è Luca?', history),
        isNull);
    expect(AssistantConversationRecall.answer('Chi è il presidente?', history),
        isNull);
  });

  test('opinions are user-attributed; never learned from assistant guesses', () {
    expect(AssistantConversationRecall.answer('e che cosa è Mika?', const [
      ChatTurn(role: ChatRole.user, content: 'il nome del mio collega è Mika'),
      ChatTurn(role: ChatRole.assistant, content: 'Mika è un idiota'),
    ]), isNull);
    expect(AssistantConversationRecall.answer('e che cosa è?', const [
      ChatTurn(role: ChatRole.user, content: 'il nome del mio collega è Mika'),
      ChatTurn(role: ChatRole.user, content: 'ed è un idiota',
        excludeFromContext: true),
    ]), isNull);
    expect(AssistantConversationRecall.answer('e che cosa è?', const [
      ChatTurn(role: ChatRole.user, content: 'il nome del mio collega è Mika'),
      ChatTurn(role: ChatRole.user, content: 'ed è un idiota'),
      ChatTurn(role: ChatRole.user, content: 'Il mio collega si chiama Luca'),
    ]), isNull);
  });

  test('friend test preamble survives Italian to French language switch', () {
    const history = <ChatTurn>[
      ChatTurn(role: ChatRole.user,
        content: 'Per questa prova, il mio amico si chiama Étienne.'),
    ];
    expect(AssistantConversationRecall.answer("Comment s'appelle mon ami ?", history),
      "Ton ami s'appelle Étienne.");
    expect(AssistantConversationRecall.answer('Come si chiama il mio amico?', history),
      'Il tuo amico si chiama Étienne.');
  });

  test('S24 103627: returning to Étienne chat accepts natural phrasing', () {
    // This context is rehydrated from the same session's stored user turns.
    const etienneChat = <ChatTurn>[
      ChatTurn(role: ChatRole.user,
        content: 'Per questa prova, il mio amico si chiama Étienne.'),
      ChatTurn(role: ChatRole.assistant,
        content: 'Capito. Il tuo amico si chiama Étienne.'),
      ChatTurn(role: ChatRole.user, content: "Comment s'appelle mon ami ?"),
      ChatTurn(role: ChatRole.assistant,
        content: "Ton ami s'appelle Étienne."),
      ChatTurn(role: ChatRole.user, content: 'Come si chiama il mio amico?'),
      ChatTurn(role: ChatRole.assistant,
        content: 'Il tuo amico si chiama Étienne.'),
    ];
    expect(
      AssistantConversationRecall.answer(
        'Ti ricordi come si chiama il mio amico?', etienneChat),
      'Il tuo amico si chiama Étienne.',
    );
    expect(
      AssistantConversationRecall.answer(
        'Est que tu connais Étienne?', etienneChat),
      "Tu m'as dit que ton ami s'appelle Étienne, "
          "mais je ne le connais pas personnellement.",
    );
    expect(
      AssistantConversationRecall.answer(
        'Est-ce que tu connais Étienne ?', etienneChat),
      "Tu m'as dit que ton ami s'appelle Étienne, "
          "mais je ne le connais pas personnellement.",
    );
    expect(AssistantConversationRecall.answer(
      'Est-ce que tu connais Luca ?', etienneChat), isNull);
    // Mika was declared in a different chat, never leak across sessions.
    expect(AssistantConversationRecall.answer(
      'e come si chiama il mio collega?', etienneChat), isNull);
  });

  test('S24 103627: colleague question prefix works only in Mika session', () {
    const mikaChat = <ChatTurn>[
      ChatTurn(role: ChatRole.user,
        content: 'Il nome del mio collega è Mika.'),
      ChatTurn(role: ChatRole.assistant,
        content: 'Capito. Parliamo di Mika.'),
    ];
    expect(AssistantConversationRecall.answer(
      'e come si chiama il mio collega?', mikaChat),
      'Il tuo collega si chiama Mika.');
    expect(AssistantConversationRecall.answer(
      'Ti ricordi come si chiama il mio collega?', mikaChat),
      'Il tuo collega si chiama Mika.');
    expect(AssistantConversationRecall.answer(
      'e come si chiama il mio collega?', const <ChatTurn>[]), isNull);
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
