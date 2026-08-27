import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

/// Stable Workshop-facing adapter over the application's existing
/// [InferenceService].
///
/// The Workshop remains independent from the Assistant UI and orchestration,
/// while reusing the same inference infrastructure already used by the
/// application.
///
/// Architecture:
///
///   WorkshopInferenceGateway
///          ↓
///   WorkshopInferenceProviderAdapter
///          ↓
///   InferenceService
///          ↓
///   LocalRuntimeProvider / CloudRuntimeProvider
///
/// This adapter deliberately contains no model-selection logic of its own.
/// Model selection, runtime mode, local model validation, cloud routing and
/// session handling remain responsibilities of [InferenceService].
final class WorkshopInferenceProviderAdapter
    implements RuntimeInferenceProvider {
  WorkshopInferenceProviderAdapter({
    required InferenceService inferenceService,
  }) : _inferenceService = inferenceService;

  final InferenceService _inferenceService;

  /// Returns the application's existing inference stream.
  ///
  /// The Workshop-facing contract remains RuntimeInferenceProvider, while
  /// the actual runtime selection continues to belong to InferenceService.
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Stream<InferenceResponse>.error(
        StateError(
          'Workshop inference request was cancelled before start.',
        ),
      );
    }

    return _inferenceService.stream(
      request,
    );
  }

  /// Cancels an active Workshop inference session.
  ///
  /// Cancellation is delegated to the existing InferenceService session
  /// manager. The Workshop does not need direct access to Assistant internals.
  void cancel(
    String sessionId,
  ) {
    final normalizedSessionId = sessionId.trim();

    if (normalizedSessionId.isEmpty) {
      return;
    }

    _inferenceService.cancel(
      normalizedSessionId,
    );
  }
}
