import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat/data/services/live_chat_transcript_recorder.dart';

class _FakeMessages extends Fake implements ChatLocalDataSource {
  final messages = <ChatMessageModel>[];

  @override
  Future<void> insertMessage(ChatMessageModel message) async {
    messages.add(message);
  }
}

void main() {
  test('Live question and response are kept in the active chat', () async {
    final local = _FakeMessages();
    final recorder = LiveChatTranscriptRecorder(localDataSource: local);
    await recorder.append(
        sessionId: 'chat-1', role: 'user', text: '  Come stai?  ');
    await recorder.append(
        sessionId: 'chat-1', role: 'assistant', text: ' Bene, grazie. ');

    expect(local.messages, hasLength(2));
    expect(local.messages.map((m) => m.role), ['user', 'assistant']);
    expect(local.messages.map((m) => m.content), ['Come stai?', 'Bene, grazie.']);
    expect(local.messages.every((m) => m.sessionId == 'chat-1'), isTrue);
    expect(local.messages.every((m) => m.provider == 'live-local'), isTrue);
    expect(local.messages[0].id, isNot(local.messages[1].id));
  });

  test('empty content is not written into local history', () async {
    final local = _FakeMessages();
    await LiveChatTranscriptRecorder(localDataSource: local)
        .append(sessionId: 'chat-1', role: 'user', text: '  ');
    expect(local.messages, isEmpty);
  });

  test('invalid role and blank session are rejected', () async {
    final recorder = LiveChatTranscriptRecorder(localDataSource: _FakeMessages());
    await expectLater(
        recorder.append(sessionId: 'chat-1', role: 'system', text: 'x'),
        throwsArgumentError);
    await expectLater(
        recorder.append(sessionId: '  ', role: 'user', text: 'x'),
        throwsArgumentError);
  });

  test('local write failure is propagated, not silently hidden', () async {
    final recorder =
        LiveChatTranscriptRecorder(localDataSource: _FailingMessages());
    await expectLater(
        recorder.append(sessionId: 'chat-1', role: 'assistant', text: 'x'),
        throwsStateError);
  });
}

class _FailingMessages extends Fake implements ChatLocalDataSource {
  @override
  Future<void> insertMessage(ChatMessageModel message) async =>
      throw StateError('database-unavailable');
}
