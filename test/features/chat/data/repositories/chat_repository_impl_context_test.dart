import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/features/chat/data/datasources/chat_local_datasource.dart';
import 'package:ai_orchestrator/features/chat/data/models/chat_message_model.dart';
import 'package:ai_orchestrator/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:ai_orchestrator/features/chat_memory/conversation_memory_service.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/token_estimator.dart';
import 'package:ai_orchestrator/features/chat_memory/memory_window_manager.dart';
import 'package:ai_orchestrator/features/chat_memory/rolling_context_builder.dart';
import 'package:ai_orchestrator/features/semantic_index/semantic_workspace_index.dart';
import 'package:ai_orchestrator/features/semantic_index/workspace_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _fact = 'The sample project color is indigo.';
const _reread = 'rileggere questa chat, e rispondere alla domanda';

ChatRepositoryImpl _repository(
  _SavedRows store,
  _RecordingOrchestrator runtime, {
  AiRuntimeMode mode = AiRuntimeMode.local,
}) => ChatRepositoryImpl(
  localDataSource: store,
  orchestrator: runtime,
  runtimeSettingsService: _Settings(mode),
  conversationMemoryService: ConversationMemoryService(
    rollingContextBuilder: RollingContextBuilder(
      windowManager: MemoryWindowManager(
        tokenEstimator: const CharacterLengthEstimator(),
        configProvider: () => MemoryWindowConfig.standard(isWeb: false),
      ),
    ),
    semanticWorkspaceIndex: _NoopIndex(),
    embeddingService: const _NoopEmbedding(),
  ),
);

void main() {
  test('Cloud and Hybrid keep the portable recalled exchanges before their provider bound', () async {
    for (final mode in [AiRuntimeMode.cloud, AiRuntimeMode.hybrid]) {
      final store = _SavedRows();
      for (var i = 0; i < 15; i++) {
        await store.insertMessage(
          ChatMessageModel(
            id: 'u$i',
            sessionId: 's',
            role: 'user',
            content: 'Topic $i',
            timestamp: i * 2,
          ),
        );
        await store.insertMessage(
          ChatMessageModel(
            id: 'a$i',
            sessionId: 's',
            role: 'assistant',
            content: 'Answer $i',
            timestamp: i * 2 + 1,
          ),
        );
      }
      final runtime = _RecordingOrchestrator();
      await _repository(
        store,
        runtime,
        mode: mode,
      ).sendMessage(sessionId: 's', userPrompt: 'Come avevamo deciso?');
      expect(runtime.contexts.single, hasLength(24));
      expect(runtime.contexts.single.take(4).map((t) => t.content), [
        'Topic 1',
        'Answer 1',
        'Topic 2',
        'Answer 2',
      ]);
      expect(runtime.contexts.single.last.content, 'Answer 14');
    }
  });

  test('persisted fact and failed question reach retry without duplicate IDs after reconstruction', () async {
    final store = _SavedRows();
    for (var i = 0; i < 15; i++) {
      await store.insertMessage(
        ChatMessageModel(
          id: 'u$i',
          sessionId: 's',
          role: 'user',
          content: i == 0 ? _fact : 'Topic $i',
          timestamp: i * 2,
        ),
      );
      await store.insertMessage(
        ChatMessageModel(
          id: 'a$i',
          sessionId: 's',
          role: 'assistant',
          content: 'Answer $i',
          timestamp: i * 2 + 1,
        ),
      );
    }
    final initialIds = (await store.getMessages('s')).map((m) => m.id).toList();
    final runtime = _RecordingOrchestrator()..failNext = true;
    final repository = _repository(store, runtime);
    await expectLater(
      repository.sendMessage(sessionId: 's', userPrompt: _reread),
      throwsA(isA<ServerFailure>()),
    );
    expect(runtime.contexts.single, hasLength(30));
    expect(runtime.prompts.single, contains(_fact));
    final failedSnapshot = await store.getMessages('s');
    expect(failedSnapshot, hasLength(31));
    expect(failedSnapshot.last.role, 'user');
    expect(failedSnapshot.last.content, _reread);

    // Rehydrate the actual message serialization into fresh repository/memory
    // instances. This checks the persistence boundary, not OS process restart.
    final reopenedStore = _SavedRows();
    for (final message in failedSnapshot) {
      await reopenedStore.insertMessage(
        ChatMessageModel.fromMap(message.toMap()),
      );
    }
    final reopenedRuntime = _RecordingOrchestrator();
    final reopened = _repository(reopenedStore, reopenedRuntime);
    await reopened.sendMessage(sessionId: 's', userPrompt: 'riprova');
    expect(reopenedRuntime.contexts.single, hasLength(31));
    expect(reopenedRuntime.contexts.single.last.content, _reread);
    expect(reopenedRuntime.prompts.single, contains(_fact));
    final after = await reopenedStore.getMessages('s');
    expect(after, hasLength(33));
    expect(after.take(30).map((m) => m.id), initialIds);
    expect(after.where((m) => m.id == failedSnapshot.last.id), hasLength(1));
    expect(after.map((m) => m.id).toSet(), hasLength(33));
    expect(after.where((m) => m.content == _reread), hasLength(1));
    expect(after.where((m) => m.content == 'riprova'), hasLength(1));
  });

  test(
    'clear and another session do not resurrect earlier facts or retry intent',
    () async {
      final store = _SavedRows();
      await store.insertMessage(
        const ChatMessageModel(
          id: 'fact',
          sessionId: 's',
          role: 'user',
          content: _fact,
          timestamp: 1,
        ),
      );
      await store.insertMessage(
        const ChatMessageModel(
          id: 'failed',
          sessionId: 's',
          role: 'user',
          content: _reread,
          timestamp: 2,
        ),
      );
      final runtime = _RecordingOrchestrator();
      final repository = _repository(store, runtime);
      await repository.sendMessage(sessionId: 'other', userPrompt: 'riprova');
      expect(runtime.contexts.last, isEmpty);
      expect(runtime.prompts.last, isNot(contains(_fact)));
      final otherIds = (await store.getMessages('other'))
          .map((m) => m.id)
          .toList();
      await repository.clearSession('s');
      final reopened = _repository(store, runtime);
      await reopened.sendMessage(sessionId: 's', userPrompt: 'riprova');
      expect(runtime.contexts.last, isEmpty);
      expect(runtime.prompts.last, isNot(contains(_fact)));
      expect((await store.getMessages('other')).map((m) => m.id), otherIds);
      expect((await store.getMessages('s')).map((m) => m.content), [
        'riprova',
        'OK',
      ]);
    },
  );
}

class _SavedRows implements ChatLocalDataSource {
  final _rows = <ChatMessageModel>[];
  @override
  Future<void> insertMessage(ChatMessageModel message) async =>
      _rows.add(message);
  @override
  Future<List<ChatMessageModel>> getMessages(String sessionId) async =>
      _rows.where((m) => m.sessionId == sessionId).toList();
  @override
  Future<int> clearSession(String sessionId) async {
    final before = _rows.length;
    _rows.removeWhere((m) => m.sessionId == sessionId);
    return before - _rows.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements AiRuntimeSettingsService {
  _Settings(this.runtimeMode);
  @override
  final AiRuntimeMode runtimeMode;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingOrchestrator implements Orchestrator {
  final contexts = <List<ChatTurn>>[];
  final prompts = <String>[];
  bool failNext = false;
  @override
  Stream<InferenceResponse> handleStream(
    String input, {
    required String sessionId,
    List<ChatTurn> context = const [],
    String? systemPrompt,
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
  }) {
    contexts.add(List<ChatTurn>.of(context));
    prompts.add(
      LocalPromptTemplates.compose(
        modelId: 'phi3_5_mini',
        prompt: input,
        context: context,
        systemPrompt: systemPrompt,
      ),
    );
    if (failNext) {
      failNext = false;
      return Stream.value(InferenceResponse.error('test inference failure'));
    }
    return Stream.value(
      InferenceResponse.finalChunk(text: 'OK', tokensGenerated: 1),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopEmbedding extends WorkspaceEmbeddingService {
  const _NoopEmbedding();
  @override
  Future<List<double>> embedTextAsync(String text) async => [1, 0];
}

class _NoopIndex extends SemanticWorkspaceIndex {
  _NoopIndex() : super(databaseHelper: DatabaseHelper.instance);
  @override
  Future<void> upsertChunk({
    required String workspaceId,
    required String documentPath,
    String? documentTitle,
    required int chunkIndex,
    required String chunkText,
    required List<double> vector,
  }) async {}
  @override
  Future<void> clearWorkspace(String workspaceId) async {}
  @override
  Future<List<SemanticChunkMatch>> search({
    required List<double> queryVector,
    String? workspaceId,
    int topK = 6,
  }) => throw StateError('No semantic hot-path query');
}
