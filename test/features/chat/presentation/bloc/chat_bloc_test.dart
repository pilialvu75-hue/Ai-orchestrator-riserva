import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/load_chat_messages.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/prune_chat_history.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatBloc', () {
    test('emits incremental assistant updates before loading persisted messages',
        () async {
      final persistedMessages = <ChatMessage>[];
      final repository = _FakeChatRepository(
        onGetMessages: (_) async => List<ChatMessage>.from(persistedMessages),
        onSendMessage: ({
          required String sessionId,
          required String userPrompt,
          String? systemPrompt,
          List<ChatAttachment> attachments = const <ChatAttachment>[],
          void Function(String partialText)? onPartialResponse,
          void Function(String notice)? onRuntimeNotice,
        }) async {
          onPartialResponse?.call('Par');
          onPartialResponse?.call('Partial');
          final finalMessage = ChatMessage(
            id: 'assistant-final',
            sessionId: sessionId,
            role: 'assistant',
            content: 'Partial response',
            timestamp: 2,
            provider: 'local',
          );
          persistedMessages
            ..add(
              ChatMessage(
                id: 'user-1',
                sessionId: sessionId,
                role: 'user',
                content: userPrompt,
                timestamp: 1,
                attachments: attachments,
              ),
            )
            ..add(finalMessage);
          return finalMessage;
        },
      );
      final bloc = ChatBloc(
        streamChatMessage: StreamChatMessage(repository),
        loadChatMessages: LoadChatMessages(repository),
        pruneChatHistory: PruneChatHistory(repository),
      );

      final emittedStates = <ChatState>[];
      final subscription = bloc.stream.listen(emittedStates.add);

      bloc.add(const SendMessageEvent(
        sessionId: 'session-1',
        userPrompt: 'hello',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await subscription.cancel();
      await bloc.close();

      final sendingStates = emittedStates.whereType<ChatSending>().toList();
      expect(sendingStates, isNotEmpty);
      expect(
        sendingStates.any(
          (state) => state.messages.any(
            (message) =>
                message.role == 'assistant' && message.content == 'Par',
          ),
        ),
        isTrue,
      );
      expect(
        sendingStates.any(
          (state) => state.messages.any(
            (message) =>
                message.role == 'assistant' && message.content == 'Partial',
          ),
        ),
        isTrue,
      );

      final loadedState = emittedStates.whereType<ChatLoaded>().last;
      expect(loadedState.messages, hasLength(2));
      expect(loadedState.messages.last.content, 'Partial response');
    });
  });
}

class _FakeChatRepository implements ChatRepository {
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
