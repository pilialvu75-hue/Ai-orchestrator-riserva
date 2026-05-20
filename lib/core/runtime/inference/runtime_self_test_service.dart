import 'dart:async';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart'; // Importato per gestire l'errore di timeout
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
  static const Duration _selfTestCompletionTimeout = Duration(seconds: 60);

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

      // Iniezione della protezione da timeout per evitare il blocco sincrono nativo
      final testStream = _runtimeProvider.streamInference(
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
      ).timeout(
        _selfTestCompletionTimeout,
        onTimeout: (sink) {
          cancellationToken.cancel();
          sink.add(InferenceResponse.error(
            'Runtime self-test stream timed out before provider completion.',
          ));
          sink.close();
        },
      );

      await for (final chunk in testStream) {
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
          _log(
            '[WARMUP_FIRST_TOKEN_OK] session=$selfTestSessionId chars=${firstToken!.length}',
          );
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
            '${notes.join('\n')}\n3. Token stream: FAILED\n${streamTerminalError ?? 'FIRST_TOKEN_TIMEOUT'}',
        );
      }

      final finalText = responseBuffer.toString().trim();
      final firstTokenReceived = firstToken?.isNotEmpty ?? false;
      final livenessOk = streamAliveTicks > 1;

      notes.add('3. Token stream: OK (first token emitted)');
      notes.add(
        '4. Stream liveness: ${livenessOk ? 'OK' : 'FAILED'} (ticks=$streamAliveTicks)',
      );
      notes.add(
        '5. First token validation: ${firstTokenReceived ? 'OK' : 'FAILED'} (non-empty token emitted)',
      );
      notes.add(
        '6. Completion: ${completed ? 'OK' : 'FAILED'}',
      );

      if (livenessOk) {
        _log('[WARMUP_LIVENESS_OK] session=$selfTestSessionId ticks=$streamAliveTicks');
      }

      final pass = firstTokenReceived && livenessOk && completed;
      if (!pass) {
        _log(
          '[COMM_TEST_FAIL] first_token_received=$firstTokenReceived stream_alive_ticks=$streamAliveTicks completed=$completed',
        );
        return RuntimeSelfTestResult(
          success: false,
          summary:
              '${notes.join('\n')}\nGenerated text:\n$finalText',
        );
      }

      _log(
        '[WARMUP_VALIDATION_PASS] session=$selfTestSessionId first_token_received=$firstTokenReceived liveness_ok=$livenessOk completed=$completed',
      );
      _log(
        '[COMM_TEST_PASS] first_token_received=$firstTokenReceived first_token="$firstToken"',
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
