import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';

class RuntimeSelfTestResult {
  const RuntimeSelfTestResult({
    required this.success,
    required this.summary,
  });

  final bool success;
  final String summary;
}

class RuntimeSelfTestService {
  const RuntimeSelfTestService({
    required LocalRuntimeProvider runtimeProvider,
    required LocalAiRepository localAiRepository,
    required ChatRepository chatRepository,
  })  : _runtimeProvider = runtimeProvider,
        _localAiRepository = localAiRepository,
        _chatRepository = chatRepository;

  static const String selfTestSessionId = 'runtime_self_test';

  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;
  final ChatRepository _chatRepository;

  Future<RuntimeSelfTestResult> run() async {
    final notes = <String>[];

    try {
      final selectedResult = await _localAiRepository.getSelectedModel();
      final selectedModel = selectedResult.fold((_) => null, (model) => model);
      if (selectedModel == null || selectedModel.localPath == null) {
        return const RuntimeSelfTestResult(
          success: false,
          summary:
              '1. Model exists: FAILED\nNo selected validated local model was found.',
        );
      }

      notes.add('1. Model exists: OK (${selectedModel.localPath})');

      final validation =
          await _runtimeProvider.validateRuntime(selectedModel: selectedModel);
      if (validation.status == LocalRuntimeStatus.ffiMissing ||
          validation.status == LocalRuntimeStatus.modelMissing ||
          validation.status == LocalRuntimeStatus.failed) {
        return RuntimeSelfTestResult(
          success: false,
          summary:
              '${notes.join('\n')}\n2. Runtime validation: FAILED\n${validation.message ?? 'Local runtime prerequisites are not satisfied.'}',
        );
      }
      notes.add(
        '2. Runtime validation: OK (${validation.status.name}${validation.message == null ? '' : ' – ${validation.message}'})',
      );

      await _chatRepository.clearSession(selfTestSessionId);

      var streamedPartialCount = 0;
      var lastPartialLength = 0;
      await _chatRepository.sendMessage(
        sessionId: selfTestSessionId,
        userPrompt: 'Say hello',
        onPartialResponse: (partialText) {
          final trimmed = partialText.trim();
          if (trimmed.isNotEmpty && partialText.length > lastPartialLength) {
            lastPartialLength = partialText.length;
            streamedPartialCount++;
          }
        },
      );

      final persistedMessages =
          await _chatRepository.getMessages(selfTestSessionId);
      final persistedAssistant = persistedMessages
          .where((message) => message.role == 'assistant')
          .where((message) => message.content.trim().isNotEmpty)
          .toList();
      final persistedUser = persistedMessages
          .where((message) => message.role == 'user')
          .toList();

      if (streamedPartialCount <= 0) {
        return RuntimeSelfTestResult(
          success: false,
          summary:
              '${notes.join('\n')}\n3. Token stream: FAILED\nThe runtime returned no streamed partial tokens for the real prompt.',
        );
      }

      notes.add('3. Token stream: OK ($streamedPartialCount partial updates)');

      if (persistedUser.isEmpty || persistedAssistant.isEmpty) {
        return RuntimeSelfTestResult(
          success: false,
          summary:
              '${notes.join('\n')}\n4. SQLite persistence: FAILED\nExpected persisted user + assistant rows in chat_history for $selfTestSessionId.',
        );
      }

      final assistant = persistedAssistant.last;
      notes.add(
        '4. SQLite persistence: OK (${persistedMessages.length} rows; final assistant chars=${assistant.content.length})',
      );

      return RuntimeSelfTestResult(
        success: true,
        summary: '${notes.join('\n')}\n5. Final response: ${assistant.content}',
      );
    } catch (error) {
      return RuntimeSelfTestResult(
        success: false,
        summary:
            '${notes.join('\n')}\nRuntime Self-Test aborted with error:\n$error',
      );
    }
  }
}
