import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

final class _MemoryNotNeeded extends Mock implements ConversationMemoryService {}
final class _CloudSettings extends Mock implements AiRuntimeSettingsService {}

final class _RecordingLocalDatasource implements ChatLocalDataSource {
  int insertions = 0;
  int reads = 0;

  @override
  Future<void> insertMessage(ChatMessageModel message) async {
    insertions++;
  }

  @override
  Future<List<ChatMessageModel>> getMessages(String sessionId) async {
    reads++;
    return <ChatMessageModel>[];
  }

  @override
  Future<int> deleteOldMessages(DateTime cutoff) async => 0;
  @override
  Future<int> countMessages() async => 0;
  @override
  Future<int> deleteExcessMessages(int max) async => 0;
  @override
  Future<int> clearSession(String sessionId) async => 0;
  @override
  Future<int> deleteMessagesFrom(String sessionId, String messageId) async => 0;
}

void main() {
  const visualFixtures = <ChatAttachment>[
    ChatAttachment(
      id: 'image', type: ChatAttachmentType.image,
      path: '/synthetic/image.jpg', name: 'image.jpg',
    ),
    ChatAttachment(
      id: 'video', type: ChatAttachmentType.video,
      path: '/synthetic/video.mp4', name: 'video.mp4',
    ),
  ];

  for (final attachment in visualFixtures) {
    test('gated real Chat entry rejects ${attachment.type.name} before storage',
        () async {
      final db = _RecordingLocalDatasource();
      final settings = _CloudSettings();
      when(() => settings.runtimeMode).thenReturn(AiRuntimeMode.cloud);
      final repository = ChatRepositoryImpl(
        localDataSource: db,
        conversationMemoryService: _MemoryNotNeeded(),
        runtimeSettingsService: settings,
        consentGatedAssistantCloud: true,
      );

      await expectLater(
        repository.sendMessage(
          sessionId: 'synthetic-chat',
          userPrompt: 'Analizza il contenuto',
          attachments: <ChatAttachment>[attachment],
        ),
        throwsA(isA<ServerFailure>().having(
          (failure) => failure.message,
          'user notice',
          contains('Nessun file e stato inviato'),
        )),
      );
      expect(db.insertions, 0);
      expect(db.reads, 0);
    });
  }
}
