import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_conversation_storage.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Cantiere Web conversation survives a storage reopen', () async {
    final first = await WorkshopWebConversationStorage.open();
    await first.save(const <ChatTurn>[
      ChatTurn(role: ChatRole.user, content: 'app per camminare'),
      ChatTurn(role: ChatRole.assistant, content: 'Proposta pronta.'),
    ]);

    final reopened = await WorkshopWebConversationStorage.open();
    expect(
      await reopened.load(),
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'app per camminare'),
        ChatTurn(role: ChatRole.assistant, content: 'Proposta pronta.'),
      ],
    );
  });

  test('system/runtime turns are never persisted in browser history', () async {
    final storage = await WorkshopWebConversationStorage.open();
    await storage.save(const <ChatTurn>[
      ChatTurn(role: ChatRole.system, content: 'secret runtime marker'),
      ChatTurn(role: ChatRole.user, content: 'ciao'),
    ]);

    expect(
      await storage.load(),
      const <ChatTurn>[
        ChatTurn(role: ChatRole.user, content: 'ciao'),
      ],
    );
  });
}
