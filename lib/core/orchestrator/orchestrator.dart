import 'package:ai_orchestrator/core/orchestrator/execution_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/intent_analyzer.dart';
import 'package:ai_orchestrator/core/orchestrator/task_type.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_constants.dart';

/// Central routing layer for all AI calls.
///
/// Step 3 – execution engine: classifies the user intent with [IntentAnalyzer],
/// delegates device commands to [ExecutionEngine] (platform-specific), and
/// routes AI chat queries through [InferenceService].
class Orchestrator {
  Orchestrator({
    required IntentAnalyzer intentAnalyzer,
    required ExecutionEngine executor,
    required InferenceService inferenceService,
  })  : _analyzer = intentAnalyzer,
        _executor = executor,
        _inferenceService = inferenceService;

  final IntentAnalyzer _analyzer;
  final ExecutionEngine _executor;
  final InferenceService _inferenceService;

  Future<InferenceResponse> handle(
    String input, {
    String? systemPrompt,
    bool isOffline = false,
  }) async {
    final type = _analyzer.analyze(input);

    switch (type) {
      case TaskType.command:
        return _executeCommand(input);
      case TaskType.chat:
      case TaskType.system:
      default:
        return _inferenceService.infer(
          InferenceRequest(
            sessionId: 'default',
            prompt: input,
            systemPrompt: systemPrompt,
            isOffline: isOffline,
          ),
        );
    }
  }

  TokenStream handleStream(
    String input, {
    required String sessionId,
    List<String> context = const <String>[],
    String? systemPrompt,
    bool isOffline = false,
    int maxTokens = 256,
    double temperature = 0.7,
  }) {
    final type = _analyzer.analyze(input);

    if (type == TaskType.command) {
      return Stream<InferenceResponse>.fromFuture(_executeCommand(input));
    }

    return _inferenceService.stream(
      InferenceRequest(
        sessionId: sessionId,
        prompt: input,
        systemPrompt: systemPrompt,
        context: context,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
      ),
    );
  }

  Future<InferenceResponse> _executeCommand(String input) async {
    final commandOutput = await _executor.execute(input);
    return InferenceResponse.finalChunk(
      text: commandOutput,
      model: InferenceConstants.localModelName,
      tokensGenerated: 0,
    );
  }
}
