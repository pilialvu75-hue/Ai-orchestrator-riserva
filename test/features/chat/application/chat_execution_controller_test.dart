import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/i_chat_repository.dart';
import 'package:ai_orchestrator/features/chat/application/chat_execution_controller.dart';

void main() {
  test('one authorized execution is shared instead of duplicated', () async {
    final repository = _ControlledChatRepository();
    final controller = ChatExecutionController(chatRepository: repository);

    final first = controller.send(sessionId: 'default', userPrompt: 'ciao');
    final second = controller.send(sessionId: 'default', userPrompt: 'duplicato');

    expect(identical(first, second), isTrue);
    expect(repository.sendCount, 1);
    expect(controller.state.status, ChatExecutionStatus.running);

    repository.emitPartial('risposta ');
    repository.emitNotice('Cloud provider: Gemini');
    expect(controller.state.partialText, 'risposta ');
    expect(controller.state.runtimeNotice, 'Cloud provider: Gemini');

    repository.complete(_assistant('risposta completa'));
    final result = await first;

    expect(result.content, 'risposta completa');
    expect(controller.state.status, ChatExecutionStatus.succeeded);
    expect(controller.state.finishedAt, isNotNull);

    controller.dispose();
  });

  test('execution completes with no UI listener attached', () async {
    final repository = _ControlledChatRepository();
    final controller = ChatExecutionController(chatRepository: repository);

    final run = controller.send(sessionId: 'default', userPrompt: 'background');

    // No listener is attached: the application-owned controller still owns the
    // request and the repository remains responsible for final persistence.
    repository.complete(_assistant('finita in background'));
    await run;

    expect(controller.state.status, ChatExecutionStatus.succeeded);
    expect(controller.state.result?.content, 'finita in background');

    controller.dispose();
  });
}

final class _ControlledChatRepository implements IChatRepository {
  final Completer<ChatMessage> _completer = Completer<ChatMessage>();
  int sendCount = 0;
  void Function(String)? _partial;
  void Function(String)? _notice;

  void emitPartial(String value) => _partial?.call(value);
  void emitNotice(String value) => _notice?.call(value);
  void complete(ChatMessage value) => _completer.complete(value);

  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) {
    sendCount += 1;
    _partial = onPartialResponse;
    _notice = onRuntimeNotice;
    return _completer.future;
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => const [];

  @override
  Future<int> pruneHistory({int maxAgeDays = 30, int maxRows = 1000}) async => 0;

  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;
}

ChatMessage _assistant(String content) => ChatMessage(
      id: 'assistant-1',
      sessionId: 'default',
      role: 'assistant',
      content: content,
      timestamp: 1,
      provider: 'gemini',
    );
