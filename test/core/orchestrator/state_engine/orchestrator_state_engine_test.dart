import 'dart:async';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_event.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_state.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OrchestratorStateEngine', () {
    testWidgets(
      'keeps an outstanding send owned beyond the old UI deadline and displays its late reply',
      (tester) async {
        late Completer<ChatMessage> completion;
        var calls = 0;
        final answer = ChatMessage(
          id: 'late-answer',
          sessionId: 'session-1',
          role: 'assistant',
          content: 'Parigi',
          timestamp: 3,
        );
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments = const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) {
            calls++;
            // Create the future inside the same error zone as sendMessage.
            completion = Completer<ChatMessage>();
            return completion.future;
          },
          onGetMessages: (_) async => <ChatMessage>[answer],
        );
        final engine = OrchestratorStateEngine(chatRepository: repository);
        final subscription = engine.stream.listen((_) {});
        engine.add(const SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Capitale della Francia?',
        ));
        await tester.pump();
        // Cross both the former release (55s) and debug (140s) deadlines.
        await tester.pump(const Duration(minutes: 3));
        expect(engine.state, isA<ChatSending>());

        engine.add(const SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Seconda domanda',
        ));
        await tester.pump();
        expect(calls, 1);
        expect(engine.state, isA<ChatSending>());

        completion.complete(answer);
        await tester.pump();
        final loaded = engine.state as ChatLoaded;
        expect(loaded.messages.single.content, 'Parigi');
        expect(loaded.runtimeMessage, isNull);
        // Close subscriptions outside the widget test's fake async zone.
        await tester.runAsync(() async {
          await subscription.cancel();
          await engine.close().timeout(const Duration(seconds: 5));
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    testWidgets(
      'reports a repository timeout and allows a subsequent request',
      (tester) async {
        late Completer<ChatMessage> completion;
        var calls = 0;
        final repository = _FakeChatRepository(
          onSendMessage: ({
            required String sessionId,
            required String userPrompt,
            String? systemPrompt,
            List<ChatAttachment> attachments = const <ChatAttachment>[],
            void Function(String partialText)? onPartialResponse,
            void Function(String notice)? onRuntimeNotice,
          }) {
            calls++;
            // Create the future inside the same error zone as sendMessage.
            completion = Completer<ChatMessage>();
            return completion.future;
          },
          onGetMessages: (_) async => <ChatMessage>[],
        );
        final engine = OrchestratorStateEngine(chatRepository: repository);
        final subscription = engine.stream.listen((_) {});
        const event = SendMessageEvent(
          sessionId: 'session-1',
          userPrompt: 'Ciao',
        );
        engine.add(event);
        await tester.pump();
        completion.completeError(TimeoutException('runtime deadline'));
        await tester.pump();
        expect(engine.state, isA<ChatLoaded>());
        expect(
          (engine.state as ChatLoaded).runtimeMessage,
          contains('runtime deadline'),
        );
        engine.add(event);
        await tester.pump();
        expect(calls, 2);
        completion.complete(ChatMessage(
          id: 'second-answer',
          sessionId: 'session-1',
          role: 'assistant',
          content: 'Ciao',
          timestamp: 4,
        ));
        await tester.pump();
        expect(engine.state, isA<ChatLoaded>());
        // Close subscriptions outside the widget test's fake async zone.
        await tester.runAsync(() async {
          await subscription.cancel();
          await engine.close().timeout(const Duration(seconds: 5));
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

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
