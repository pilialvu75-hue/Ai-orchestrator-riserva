import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

/// Direct inference boundary for the Workshop/Cantiere.
///
/// The Workshop intentionally does not depend on the Assistant Chat.
///
/// It uses the existing RuntimeInferenceProvider abstraction directly:
///
/// Workshop
///   -> WorkshopInferenceGateway
///   -> RuntimeInferenceProvider
///   -> Local / Cloud runtime
///
/// No Assistant UI, Assistant memory or Assistant orchestration is involved.
class WorkshopInferenceGateway {
  WorkshopInferenceGateway({
    required RuntimeInferenceProvider provider,
  }) : _provider = provider;

  final RuntimeInferenceProvider _provider;

  /// Starts a Workshop inference stream.
  ///
  /// [context] must contain Workshop/project conversation turns only.
  /// The Assistant conversation is never implicitly included.
  Stream<InferenceResponse> stream({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) {
    final normalizedPrompt = prompt.trim();

    if (normalizedPrompt.isEmpty) {
      return Stream<InferenceResponse>.error(
        ArgumentError(
          'WorkshopInferenceGateway requires a non-empty prompt.',
        ),
      );
    }

    final token = cancellationToken ?? CancellationToken();

    final request = InferenceRequest(
      sessionId: sessionId,
      prompt: normalizedPrompt,
      systemPrompt: systemPrompt,
      context: List<ChatTurn>.unmodifiable(context),
      isOffline: isOffline,
      maxTokens: maxTokens ??
          InferenceRequest.maxTokensForModel(modelId),
      temperature: temperature ??
          InferenceRequest.temperatureForModel(modelId),
      topP: topP,
      repeatPenalty: repeatPenalty,
      modelId: modelId,
      modelPath: modelPath,
    );

    return _provider.streamInference(
      request: request,
      cancellationToken: token,
    );
  }

  /// Convenience method that collects a complete Workshop response.
  ///
  /// This does not create another inference path. It simply consumes
  /// [stream] and accumulates its text.
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    final buffer = StringBuffer();

    String? model;
    String? runtimeNotice;
    InferenceTerminalState? terminalState;
    String? errorMessage;

    await for (final response in stream(
      prompt: prompt,
      systemPrompt: systemPrompt,
      context: context,
      sessionId: sessionId,
      isOffline: isOffline,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      repeatPenalty: repeatPenalty,
      modelId: modelId,
      modelPath: modelPath,
      cancellationToken: cancellationToken,
    )) {
      if (response.model != null &&
          response.model!.trim().isNotEmpty) {
        model = response.model;
      }

      if (response.runtimeNotice != null &&
          response.runtimeNotice!.trim().isNotEmpty) {
        runtimeNotice = response.runtimeNotice;
      }

      if (response.text.isNotEmpty) {
        buffer.write(response.text);
      }

      if (response.isFinal) {
        terminalState = response.terminalState;

        if (response.isError) {
          errorMessage = response.errorMessage;
        }
      }
    }

    return WorkshopInferenceResult(
      text: buffer.toString(),
      model: model,
      runtimeNotice: runtimeNotice,
      terminalState: terminalState,
      errorMessage: errorMessage,
    );
  }
}

/// Result of a completed Workshop inference request.
class WorkshopInferenceResult {
  const WorkshopInferenceResult({
    required this.text,
    this.model,
    this.runtimeNotice,
    this.terminalState,
    this.errorMessage,
  });

  final String text;
  final String? model;
  final String? runtimeNotice;
  final InferenceTerminalState? terminalState;
  final String? errorMessage;

  bool get hasText => text.trim().isNotEmpty;

  bool get hasError => errorMessage != null;

  bool get isSuccessful =>
      !hasError &&
      terminalState == InferenceTerminalState.success;

  @override
  String toString() {
    return 'WorkshopInferenceResult('
        'textLength=${text.length}, '
        'model=$model, '
        'terminalState=$terminalState, '
        'hasError=$hasError'
        ')';
  }
}
