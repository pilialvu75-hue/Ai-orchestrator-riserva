import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OrchestratorStateEngine', () {
    test(
      'keeps partial assistant content on runtime notice for attachments-only sends',
      () async {
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments = const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) async {
            onPartialResponse?.call('partial vision response');
            onRuntimeNotice?.call('runtime still processing');
            return ChatMessage(
              id: 'assistant-final',
              sessionId: sessionId,
              role: 'assistant',
              content: 'final response',
              timestamp: 3,
              provider: 'local',
            );
          },
          onGetMessages: (sessionId) async {
            return <ChatMessage>[
              ChatMessage(
                id: 'user-final',
                sessionId: sessionId,
                role: 'user',
                content: '',
                timestamp: 1,
              ),
              ChatMessage(
                id: 'assistant-final',
                sessionId: sessionId,
                role: 'assistant',
                content: 'final response',
                timestamp: 3,
                provider: 'local',
              ),
            ];
          },
        );

        final engine = OrchestratorStateEngine(chatRepository: repository);
        final emittedStates = <ChatState>[];
        final subscription = engine.stream.listen(emittedStates.add);

        engine.add(
          SendMessageEvent(
            sessionId: 'session-1',
            userPrompt: '',
            attachments: const <ChatAttachment>[
              ChatAttachment(
                id: 'a1',
                type: ChatAttachmentType.image,
                path: '/tmp/test-image.png',
                name: 'test-image.png',
              ),
            ],
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        final sendingStates = emittedStates.whereType<ChatSending>().toList();
        final sendingStateWithNotice = sendingStates.lastWhere(
          (state) => state.runtimeMessage == 'runtime still processing',
        );
        final assistantMessages = sendingStateWithNotice.messages
            .where((message) => message.role == 'assistant')
            .toList();

        expect(assistantMessages, hasLength(1));
        expect(assistantMessages.single.content, 'partial vision response');

        await subscription.cancel();
        await engine.close();
      },
    );
  });
}

class _FakeChatRepository implements IChatRepository {
  _FakeChatRepository({
    required this.onSendMessage,
    required this.onGetMessages,
  });

  final Future<ChatMessage> Function({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments,
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) onSendMessage;
  final Future<List<ChatMessage>> Function(String sessionId) onGetMessages;

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) =>
      onGetMessages(sessionId);

  @override
  Future<int> pruneHistory({
    int maxAgeDays = 0,
    int maxRows = 0,
  }) async =>
      0;

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) {
    return onSendMessage(
      sessionId: sessionId,
      userPrompt: userPrompt,
      systemPrompt: systemPrompt,
      attachments: attachments,
      onPartialResponse: onPartialResponse,
      onRuntimeNotice: onRuntimeNotice,
    );
  }
}
