import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

/// Stable Workshop-facing inference boundary.
///
/// The Workshop and the Assistant are two independent logical brains.
/// They may share low-level runtime infrastructure, but the Workshop must
/// never inherit the model selected by the Assistant.
///
/// Architecture:
///
///   Workshop
///       ↓
///   WorkshopInferenceProviderAdapter
///       ↓
///   Workshop model assignment
///       ↓
///   Inference runtime
///
/// The adapter therefore establishes the Workshop model explicitly before
/// delegating inference to the existing runtime infrastructure.
///
/// IMPORTANT:
///
/// This class does not modify Assistant model selection.
/// The Assistant remains responsible for its own model configuration.
///
/// The Workshop has its own model assignment, beginning with the
/// [AppAiRole.workshopOrchestrator] role.
final class WorkshopInferenceProviderAdapter
    implements RuntimeInferenceProvider {
  WorkshopInferenceProviderAdapter({
    required InferenceService inferenceService,
    String? modelId,
    AppAiRole role = AppAiRole.workshopOrchestrator,
  })  : _inferenceService = inferenceService,
        _role = role,
        _configuredModelId = _normalizeModelId(modelId);

  final InferenceService _inferenceService;
  final AppAiRole _role;
  final String? _configuredModelId;

  /// Logical Workshop role currently requesting inference.
  AppAiRole get role => _role;

  /// Model explicitly configured for this Workshop adapter.
  ///
  /// When null, the adapter uses the Workshop's own role assignment.
  String? get configuredModelId => _configuredModelId;

  /// Effective Workshop model identifier.
  ///
  /// This is deliberately resolved from Workshop configuration and never from
  /// the Assistant's currently selected model.
  String get effectiveModelId {
    final configured = _configuredModelId;
    if (configured != null) {
      return configured;
    }

    final assigned = WorkshopModelAssignments.modelIdFor(_role);

    if (assigned == null || assigned.trim().isEmpty) {
      throw StateError(
        'No Workshop model is assigned to role "${_role.id}".',
      );
    }

    return assigned.trim();
  }

  /// Runs inference using the Workshop model boundary.
  ///
  /// The incoming request may contain a model identifier supplied by another
  /// layer. That value is intentionally not trusted here because the
  /// Workshop must not accidentally inherit Assistant model selection.
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

    final workshopModelId = effectiveModelId;

    final workshopRequest = request.copyWith(
      modelId: workshopModelId,
    );

    return _inferenceService.stream(
      workshopRequest,
    );
  }

  /// Cancels an active Workshop inference session.
  ///
  /// The Workshop exposes only its own cancellation boundary and does not
  /// require callers to access Assistant internals directly.
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

  static String? _normalizeModelId(String? value) {
    final normalized = value?.trim();

    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    return normalized;
  }
}
