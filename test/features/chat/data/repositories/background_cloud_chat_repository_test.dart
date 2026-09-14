import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/background_cloud_chat_repository.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';

void main() {
  test('explicit Cloud send holds lease until delegate completes', () async {
    final delegate = _ControlledRepository();
    final lease = _RecordingLease();
    final repository = BackgroundCloudChatRepository(
      delegate: delegate,
      backgroundExecution: lease,
      cloudModeActive: () => true,
    );

    final send = repository.sendMessage(
      sessionId: 'default',
      userPrompt: 'hello',
    );

    await Future<void>.delayed(Duration.zero);

    expect(lease.acquired, <String>['cloud-chat-1']);
    expect(lease.released, isEmpty);
    expect(delegate.sendCount, 1);

    delegate.complete(_assistantMessage());
    final result = await send;

    expect(result.content, 'done');
    expect(lease.released, <String>['cloud-chat-1']);
  });

  test('lease is released when Cloud delegate fails', () async {
    final delegate = _ControlledRepository();
    final lease = _RecordingLease();
    final repository = BackgroundCloudChatRepository(
      delegate: delegate,
      backgroundExecution: lease,
      cloudModeActive: () => true,
    );

    final send = repository.sendMessage(
      sessionId: 'default',
      userPrompt: 'hello',
    );

    await Future<void>.delayed(Duration.zero);
    delegate.fail(StateError('provider failed'));

    await expectLater(send, throwsStateError);
    expect(lease.acquired, <String>['cloud-chat-1']);
    expect(lease.released, <String>['cloud-chat-1']);
  });

  test('Local and Hybrid paths do not acquire Cloud lease', () async {
    final delegate = _ImmediateRepository();
    final lease = _RecordingLease();
    final repository = BackgroundCloudChatRepository(
      delegate: delegate,
      backgroundExecution: lease,
      cloudModeActive: () => false,
    );

    final result = await repository.sendMessage(
      sessionId: 'default',
      userPrompt: 'hello',
    );

    expect(result.content, 'done');
    expect(lease.acquired, isEmpty);
    expect(lease.released, isEmpty);
  });
}

final class _RecordingLease implements CloudBackgroundExecutionLease {
  final List<String> acquired = <String>[];
  final List<String> released = <String>[];

  @override
  Future<void> acquire(String leaseId) async {
    acquired.add(leaseId);
  }

  @override
  Future<void> release(String leaseId) async {
    released.add(leaseId);
  }
}

final class _ControlledRepository extends _BaseFakeRepository {
  final Completer<ChatMessage> _completer = Completer<ChatMessage>();
  int sendCount = 0;

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
    return _completer.future;
  }

  void complete(ChatMessage message) => _completer.complete(message);

  void fail(Object error) => _completer.completeError(error);
}

final class _ImmediateRepository extends _BaseFakeRepository {
  @override
  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String userPrompt,
    String? systemPrompt,
    List<ChatAttachment> attachments = const <ChatAttachment>[],
    void Function(String partialText)? onPartialResponse,
    void Function(String notice)? onRuntimeNotice,
  }) async =>
      _assistantMessage();
}

abstract class _BaseFakeRepository implements ChatRepository {
  @override
  Future<void> clearSession(String sessionId) async {}

  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      const <ChatMessage>[];

  @override
  Future<int> pruneHistory({int maxAgeDays = 30, int maxRows = 1000}) async => 0;
}

ChatMessage _assistantMessage() => const ChatMessage(
      id: 'assistant-1',
      sessionId: 'default',
      role: 'assistant',
      content: 'done',
      timestamp: 1,
      provider: 'gemini',
    );
