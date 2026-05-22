import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/domain/entities/chat_message.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/usecases/stream_chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StreamChatMessage', () {
    test('emits partial assistant updates before the final persisted message',
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
          onPartialResponse?.call('Hel');
          onPartialResponse?.call('Hello');
          return ChatMessage(
            id: 'assistant-final',
            sessionId: sessionId,
            role: 'assistant',
            content: 'Hello world',
            timestamp: 3,
            provider: 'local',
          );
        },
      );

      final usecase = StreamChatMessage(repository);
      final messages = await usecase(
        const StreamChatMessageParams(
          sessionId: 's1',
          userPrompt: 'Hi',
          activeProvider: 'local',
        ),
      ).toList();

      expect(messages, hasLength(3));
      expect(messages[0].content, 'Hel');
      expect(messages[1].content, 'Hello');
      expect(messages[2].content, 'Hello world');
      expect(messages[2].id, 'assistant-final');
    });

    test('maps repository exceptions to stream errors', () async {
      final repository = _FakeChatRepository(
        onSendMessage: ({
          required String sessionId,
          required String userPrompt,
          String? systemPrompt,
          List<ChatAttachment> attachments = const <ChatAttachment>[],
          void Function(String partialText)? onPartialResponse,
          void Function(String notice)? onRuntimeNotice,
        }) async {
          throw const ServerFailure('boom');
        },
      );

      final usecase = StreamChatMessage(repository);

      await expectLater(
        usecase(
          const StreamChatMessageParams(
            sessionId: 's1',
            userPrompt: 'Hi',
          ),
        ),
        emitsError(isA<ServerFailure>()),
      );
    });
  });
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({
    required this.onSendMessage,
    this.onGetMessages,
    this.onPruneHistory,
    this.onClearSession,
  });

  final Future<ChatMessage> Function({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments,
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) onSendMessage;
  final Future<List<ChatMessage>> Function(String sessionId)? onGetMessages;
  final Future<int> Function({
    int maxAgeDays,
    int maxRows,
  })? onPruneHistory;
  final Future<void> Function(String sessionId)? onClearSession;

  @override
  Future<void> clearSession(String sessionId) =>
      onClearSession?.call(sessionId) ?? Future<void>.value();

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) =>
      onGetMessages?.call(sessionId) ?? Future<List<ChatMessage>>.value(const []);

  @override
  Future<int> pruneHistory({
    int maxAgeDays = 0,
    int maxRows = 0,
  }) =>
      onPruneHistory?.call(maxAgeDays: maxAgeDays, maxRows: maxRows) ??
      Future<int>.value(0);

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
