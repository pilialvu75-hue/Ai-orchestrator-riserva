import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';

/// Core contract for cloud AI provider repositories.
///
/// All cloud AI feature implementations (OpenAI, Gemini, Grok, Copilot)
/// must implement this interface so the orchestration layer remains
/// decoupled from any specific provider.
abstract class AiRepository {
  /// Sends [request] to the active provider and returns the response.
  Future<Either<Failure, AiResponse>> sendQuery(AiRequest request);

  /// Sends [request] to the explicit [providerName].
  Future<Either<Failure, AiResponse>> sendQueryWithProvider(
    String providerName,
    AiRequest request,
  );

  /// Returns the identifier of the currently active provider.
  String get activeProvider;

  /// Providers currently supported by cloud runtime orchestration.
  List<String> get supportedProviders;

  /// Returns a human-readable name for the given or active provider.
  String providerDisplayName([String? providerName]);

  /// Validates the given or active provider before making a remote request.
  ///
  /// Returns `null` when the provider is ready for cloud inference.
  String? validateProviderConfiguration([String? providerName]);

  /// Returns whether [providerName] is ready for remote inference.
  bool isProviderAvailable(String providerName);

  /// Switches the active provider to [providerName].
  void setProvider(String providerName);
}
