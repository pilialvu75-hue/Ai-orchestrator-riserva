import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/features/chat/domain/repositories/chat_repository.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:flutter/foundation.dart';

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

  /// Dedicated verification session cleared before every self-test run.
  static const String selfTestSessionId = 'runtime_self_test';

  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;
  final ChatRepository _chatRepository;

  Future<RuntimeSelfTestResult> run() async {
    final notes = <String>[];
    _log('[COMM_TEST_START] session=$selfTestSessionId');

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

      final cancellationToken = CancellationToken();
      final responseBuffer = StringBuffer();
      String? firstToken;
      String? streamTerminalError;
      var emittedTokenChunks = 0;
      var streamAliveTicks = 0;
      var completed = false;
      await for (final chunk in _runtimeProvider.streamInference(
        request: InferenceRequest(
          sessionId: selfTestSessionId,
          prompt: 'Reply with the single word: OK',
          maxTokens: 4,
          temperature: 0.1,
          isOffline: true,
          modelId: selectedModel.effectiveRuntimeModelId,
          modelPath: selectedModel.localPath,
        ),
        cancellationToken: cancellationToken,
      )) {
        streamAliveTicks++;
        if (!chunk.isError && !chunk.isFinal && chunk.text.isNotEmpty) {
          responseBuffer.write(chunk.text);
          emittedTokenChunks++;
          _log(
            '[COMM_TEST_TOKEN] chunk=$emittedTokenChunks chars=${chunk.text.length}',
          );
        }
        if (!chunk.isError &&
            !chunk.isFinal &&
            chunk.text.trim().isNotEmpty &&
            firstToken == null) {
          firstToken = chunk.text.trim();
          _log('[COMM_TEST_TOKEN] first_token="$firstToken"');
        }
        if (chunk.isFinal) {
          completed = true;
          if (chunk.text.isNotEmpty) {
            responseBuffer.clear();
            responseBuffer.write(chunk.text);
          }
        }
        if (chunk.isError && firstToken == null) {
          streamTerminalError = chunk.errorMessage ?? 'unknown runtime error';
        }
      }

      if (firstToken == null) {
        _log(
          '[COMM_TEST_FAIL] reason=${streamTerminalError ?? 'generation_completed_without_token'}',
        );
        return RuntimeSelfTestResult(
          success: false,
          summary:
            '${notes.join('\n')}\n3. Token stream: FAILED\n${streamTerminalError ?? 'Generation completed without token emission.'}',
        );
      }

      final finalText = responseBuffer.toString().trim();
      final okReachedUi = RegExp(r'\bOK\b', caseSensitive: false).hasMatch(finalText);

      notes.add('3. Token stream: OK (first token emitted)');
      notes.add(
        '4. Stream liveness: ${streamAliveTicks > 1 ? 'OK' : 'FAILED'} (ticks=$streamAliveTicks)',
      );
      notes.add(
        '5. Expected token: ${okReachedUi ? 'OK' : 'FAILED'} (expected=OK)',
      );
      notes.add(
        '6. Completion: ${completed ? 'OK' : 'FAILED'}',
      );

      final pass = streamAliveTicks > 1 && okReachedUi && completed;
      if (!pass) {
        _log(
          '[COMM_TEST_FAIL] stream_alive=$streamAliveTicks expected_ok=$okReachedUi completed=$completed',
        );
        return RuntimeSelfTestResult(
          success: false,
          summary:
              '${notes.join('\n')}\nGenerated text:\n$finalText',
        );
      }

      _log(
        '[COMM_TEST_PASS] expected_ok=$okReachedUi first_token="$firstToken"',
      );

      return RuntimeSelfTestResult(
        success: pass,
        summary:
            '${notes.join('\n')}\nCommunication self-test result: PASS\nGenerated text:\n$finalText',
      );
    } catch (error) {
      _log('[COMM_TEST_FAIL] reason=exception error=$error');
      return RuntimeSelfTestResult(
        success: false,
        summary:
            '${notes.join('\n')}\nRuntime Self-Test aborted with error:\n$error',
      );
    }
  }

  static void _log(String message) {
    debugPrint('[AI_RUNTIME] $message');
  }
}
