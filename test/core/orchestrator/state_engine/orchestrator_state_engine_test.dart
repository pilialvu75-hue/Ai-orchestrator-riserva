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
      'keeps partial assistant content and Cloud provider across generic runtime notices',
      () async {
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments =
                const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) async {
            onPartialResponse?.call('partial vision response');
            onRuntimeNotice?.call('Cloud provider: Gemini');
            onRuntimeNotice?.call('runtime still processing');
            return ChatMessage(
              id: 'assistant-final',
              sessionId: sessionId,
              role: 'assistant',
              content: 'final response',
              timestamp: 3,
              provider: 'gemini',
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
                provider: 'gemini',
              ),
            ];
          },
        );

        final engine =
            OrchestratorStateEngine(chatRepository: repository);
        final emittedStates = <ChatState>[];
        final subscription =
            engine.stream.listen(emittedStates.add);

        engine.add(
          const SendMessageEvent(
            sessionId: 'session-1',
            userPrompt: '',
            attachments: <ChatAttachment>[
              ChatAttachment(
                id: 'a1',
                type: ChatAttachmentType.image,
                path: '/tmp/test-image.png',
                name: 'test-image.png',
              ),
            ],
          ),
        );

        await Future<void>.delayed(
          const Duration(milliseconds: 50),
        );

        final sendingStates =
            emittedStates.whereType<ChatSending>().toList();

        final cloudProviderState =
            sendingStates.lastWhere(
          (state) =>
              state.runtimeMessage == 'Cloud provider: Gemini',
        );
        final cloudProviderAssistant =
            cloudProviderState.messages.singleWhere(
          (message) => message.role == 'assistant',
        );
        expect(
          cloudProviderAssistant.content,
          'partial vision response',
        );
        expect(cloudProviderAssistant.provider, 'Gemini');

        final genericNoticeState =
            sendingStates.lastWhere(
          (state) =>
              state.runtimeMessage == 'runtime still processing',
        );
        final genericNoticeAssistant =
            genericNoticeState.messages.singleWhere(
          (message) => message.role == 'assistant',
        );
        expect(
          genericNoticeAssistant.content,
          'partial vision response',
        );
        expect(genericNoticeAssistant.provider, 'Gemini');

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

  final Future<List<ChatMessage>> Function(String sessionId)
      onGetMessages;

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(
    String sessionId,
    String messageId,
  ) async =>
      0;

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
    List<ChatAttachment> attachments =
        const <ChatAttachment>[],
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
