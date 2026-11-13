import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_local_json_planner.dart';

/// Isolated adapter from Computer Use to the existing LOCAL-only runtime.
/// No Cloud provider, network transport, runtime setting or model switch is
/// available through this class. It is not registered in production yet:
/// real screen reading and physical host QA must precede activation.
final class AivexusComputerUseLocalDecisionModel
    implements ComputerUseLocalDecisionModel, ComputerUseCancellableDecisionModel {
  AivexusComputerUseLocalDecisionModel({
    required LocalRuntimeProvider localRuntime,
    required this.modelId,
    required this.modelPath,
    required this.sessionId,
    this.timeout = const Duration(seconds: 35),
  }) : _runtime = localRuntime;

  final LocalRuntimeProvider _runtime;
  final String modelId;
  final String modelPath;
  final String sessionId;
  final Duration timeout;
  CancellationToken? _active;

  static const int maxOutputChars = 4096;

  @override
  void cancelPendingCompletion() => _active?.cancel();

  @override
  Future<String> completeLocally({
    required String systemInstruction,
    required String userPayload,
  }) async {
    if (_active != null) {
      throw StateError('Computer Use LOCAL model is busy.');
    }
    if (modelId.trim().isEmpty ||
        modelPath.trim().isEmpty ||
        sessionId.trim().isEmpty ||
        systemInstruction.trim().isEmpty ||
        userPayload.trim().isEmpty) {
      throw StateError('Computer Use LOCAL inference is not configured.');
    }

    final cancellation = CancellationToken();
    _active = cancellation;
    try {
      final request = InferenceRequest(
        sessionId: sessionId,
        prompt: userPayload,
        systemPrompt: systemInstruction,
        modelId: modelId,
        modelPath: modelPath,
        isOffline: true,
        routeDirective: InferenceRouteDirective.localOnly,
        allowWebSearchTool: false,
        allowCloudProviderFailover: false,
        maxTokens: 256,
        preserveMaxTokens: true,
        temperature: 0.1,
        preserveTemperature: true,
      );

      final generated = StringBuffer();
      String? finalText;
      var finished = false;
      await for (final chunk in _runtime.streamInference(
        request: request,
        cancellationToken: cancellation,
      ).timeout(timeout)) {
        if (cancellation.isCancelled) {
          throw StateError('Computer Use LOCAL inference was cancelled.');
        }
        if (chunk.isError) {
          throw StateError('Computer Use LOCAL inference failed.');
        }
        if (chunk.isFinal) {
          if (chunk.terminalState != InferenceTerminalState.success) {
            throw StateError('Computer Use LOCAL inference did not succeed.');
          }
          finalText = chunk.text;
          finished = true;
          break;
        }
        // Runtime notices are metadata, not model text.
        if (chunk.runtimeNotice != null) continue;
        generated.write(chunk.text);
        if (generated.length > maxOutputChars) {
          cancellation.cancel();
          throw const FormatException('LOCAL Computer Use response too long.');
        }
      }

      if (!finished || cancellation.isCancelled) {
        throw StateError('Computer Use LOCAL completion is not verified.');
      }
      final String answer = (finalText?.isNotEmpty ?? false)
          ? finalText!
          : generated.toString();
      if (answer.trim().isEmpty || answer.length > maxOutputChars) {
        throw const FormatException('Invalid LOCAL Computer Use output.');
      }
      return answer.trim();
    } on TimeoutException {
      cancellation.cancel();
      rethrow;
    } finally {
      if (identical(_active, cancellation)) {
        _active = null;
      }
    }
  }
}
