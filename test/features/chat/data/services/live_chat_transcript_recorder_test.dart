import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat/data/services/live_chat_transcript_recorder.dart';

class _MemoryMessages extends Fake implements ChatLocalDataSource {
  final messages = <ChatMessageModel>[];

  @override
  Future<void> insertMessage(ChatMessageModel message) async {
    messages.add(message);
  }
}

void main() {
  test('Live questions and answers persist under the same chat session', () async {
    final local = _MemoryMessages();
    final recorder = LiveChatTranscriptRecorder(localDataSource: local);
    await recorder.append(sessionId: 'chat-a', role: 'user',
        text: '  Che ore sono?  ');
    await recorder.append(sessionId: 'chat-a', role: 'assistant',
        text: ' Sono le tre. ');

    expect(local.messages, hasLength(2));
    expect(local.messages.map((m) => m.role), ['user', 'assistant']);
    expect(local.messages.map((m) => m.content),
        ['Che ore sono?', 'Sono le tre.']);
    expect(local.messages.every((m) => m.sessionId == 'chat-a'), isTrue);
    expect(local.messages.every((m) => m.provider == 'live-local'), isTrue);
    expect(local.messages[0].id, isNot(local.messages[1].id));
  });

  test('empty utterances are not saved', () async {
    final local = _MemoryMessages();
    final recorder = LiveChatTranscriptRecorder(localDataSource: local);
    await recorder.append(sessionId: 'chat-a', role: 'user', text: '  ');
    expect(local.messages, isEmpty);
  });

  test('invalid transcript role is rejected', () async {
    final recorder = LiveChatTranscriptRecorder(
        localDataSource: _MemoryMessages());
    expect(() => recorder.append(sessionId: 'a', role: 'system', text: 'x'),
        throwsArgumentError);
  });
}
