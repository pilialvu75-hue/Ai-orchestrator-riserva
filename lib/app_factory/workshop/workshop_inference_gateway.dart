import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';

/// Independent inference gateway for the Workshop/Cantiere.
///
/// The Workshop must remain operational even when the main Assistant Chat
/// is unavailable. This gateway therefore talks directly to the existing
/// inference provider abstraction and deliberately does not depend on:
///
/// - ChatPage
/// - ChatBloc/Cubit
/// - Assistant conversation state
/// - Assistant memory
/// - Assistant-specific prompts
///
/// The gateway is an adapter, not a second inference engine.
///
/// Architecture:
///
/// ```text
/// Workshop Chat
///      │
///      ▼
/// WorkshopInferenceGateway
///      │
///      ▼
/// RuntimeInferenceProvider
///      │
///      ├── Local runtime
///      └── Cloud runtime
/// ```
///
/// This keeps the Workshop independent from the Assistant while allowing
/// both surfaces to share the same proven inference infrastructure.
class WorkshopInferenceGateway {
  WorkshopInferenceGateway({
    required RuntimeInferenceProvider provider,
  }) : _provider = provider;

  final RuntimeInferenceProvider _provider;

  /// Streams an inference request for the Workshop.
  ///
  /// The caller owns the Workshop conversation and project context.
  /// Nothing from the Assistant Chat is implicitly injected here.
  ///
  /// [prompt] is the actual coding/task request.
  /// [systemPrompt] is Workshop-specific instruction/context.
  /// [sessionId] identifies the Workshop inference session.
  /// [modelId] optionally selects the model assigned to the Workshop role.
  /// [modelPath] optionally identifies a concrete local model file.
  /// [context] contains Workshop/project context only.
  /// [isOffline] controls the requested runtime mode.
  /// [maxTokens] and [temperature] are forwarded unchanged.
  /// [cancellationToken] allows the Workshop UI to cancel generation safely.
  Stream<InferenceResponse> stream({
    required String prompt,
    String? systemPrompt,
    String sessionId = 'workshop',
    String? modelId,
    String? modelPath,
    String? context,
    bool isOffline = true,
    int maxTokens = 1024,
    double temperature = 0.2,
    CancellationToken? cancellationToken,
  }) {
    final normalizedPrompt = prompt.trim();

    if (normalizedPrompt.isEmpty) {
      return Stream<InferenceResponse>.error(
        ArgumentError(
          'WorkshopInferenceGateway.stream requires a non-empty prompt.',
        ),
      );
    }

    final request = InferenceRequest(
      sessionId: sessionId,
      prompt: normalizedPrompt,
      systemPrompt: systemPrompt,
      context: context,
      isOffline: isOffline,
      maxTokens: maxTokens,
      temperature: temperature,
      modelId: modelId,
      modelPath: modelPath,
    );

    return _provider.streamInference(
      request: request,
      cancellationToken: cancellationToken,
    );
  }

  /// Executes a Workshop request and accumulates the generated text.
  ///
  /// This is intentionally a convenience method over [stream], not a second
  /// inference path. All inference still travels through the same provider.
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    String sessionId = 'workshop',
    String? modelId,
    String? modelPath,
    String? context,
    bool isOffline = true,
    int maxTokens = 1024,
    double temperature = 0.2,
    CancellationToken? cancellationToken,
  }) async {
    final buffer = StringBuffer();

    String? model;
    String? runtimeNotice;
    Object? streamError;
    StackTrace? streamStackTrace;

    var isFinal = false;

    try {
      await for (final response in stream(
        prompt: prompt,
        systemPrompt: systemPrompt,
        sessionId: sessionId,
        modelId: modelId,
        modelPath: modelPath,
        context: context,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
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
          isFinal = true;
        }

        if (response.isError) {
          streamError = response.errorMessage ??
              'Workshop inference failed.';
          isFinal = true;
          break;
        }
      }
    } catch (error, stackTrace) {
      streamError = error;
      streamStackTrace = stackTrace;
    }

    return WorkshopInferenceResult(
      text: buffer.toString(),
      model: model,
      runtimeNotice: runtimeNotice,
      isFinal: isFinal,
      error: streamError,
      stackTrace: streamStackTrace,
    );
  }
}

/// Accumulated result of a Workshop inference operation.
///
/// This class contains no Chat/Assistant state. It belongs exclusively to
/// the Workshop inference boundary.
class WorkshopInferenceResult {
  const WorkshopInferenceResult({
    required this.text,
    required this.isFinal,
    this.model,
    this.runtimeNotice,
    this.error,
    this.stackTrace,
  });

  final String text;
  final String? model;
  final String? runtimeNotice;
  final bool isFinal;
  final Object? error;
  final StackTrace? stackTrace;

  bool get hasText => text.trim().isNotEmpty;

  bool get hasError => error != null;

  bool get isSuccessful => !hasError && hasText;

  WorkshopInferenceResult copyWith({
    String? text,
    String? model,
    String? runtimeNotice,
    bool? isFinal,
    Object? error,
    StackTrace? stackTrace,
  }) {
    return WorkshopInferenceResult(
      text: text ?? this.text,
      model: model ?? this.model,
      runtimeNotice: runtimeNotice ?? this.runtimeNotice,
      isFinal: isFinal ?? this.isFinal,
      error: error ?? this.error,
      stackTrace: stackTrace ?? this.stackTrace,
    );
  }

  @override
  String toString() {
    return 'WorkshopInferenceResult('
        'textLength=${text.length}, '
        'model=$model, '
        'isFinal=$isFinal, '
        'hasError=$hasError'
        ')';
  }
}
