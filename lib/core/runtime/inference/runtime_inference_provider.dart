import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

abstract class RuntimeInferenceProvider {
  /// Runs inference for [request] and emits response chunks as a stream.
  ///
  /// [cancellationToken] is monitored by providers to stop work and emit a
  /// terminal cancellation error when the active session is cancelled.
  ///
  /// The returned [TokenStream] must emit [InferenceResponse] chunks in order
  /// and complete with either a final chunk (`isFinal = true`) or an error
  /// chunk (`isError = true`).
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  });
}
