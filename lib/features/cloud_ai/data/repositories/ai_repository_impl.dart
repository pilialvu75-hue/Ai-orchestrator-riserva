import 'package:ai_orchestrator/core/diagnostics/cloud_routing_diagnostics.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/copilot_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/custom_cloud_provider_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/gemini_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/grok_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openai_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_response.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/repositories/ai_repository.dart';
import 'package:dartz/dartz.dart';

enum ActiveAiProvider { openAi, gemini, claude, grok, copilot }

class AiRepositoryImpl implements AiRepository {
  AiRepositoryImpl({
    required this.openAiDataSource,
    required this.geminiDataSource,
    required this.claudeDataSource,
    this.grokDataSource,
    this.copilotDataSource,
    CustomCloudProviderDataSource? customCloudProviderDataSource,
    ActiveAiProvider activeAiProvider = ActiveAiProvider.openAi,
  })  : _customCloudProviderDataSource =
            customCloudProviderDataSource ?? CustomCloudProviderDataSource(),
        _activeProviderId = activeAiProvider.name;

  final OpenAiDataSource openAiDataSource;
  final GeminiDataSource geminiDataSource;
  final ClaudeDataSource claudeDataSource;
  final GrokDataSource? grokDataSource;
  final CopilotDataSource? copilotDataSource;
  final CustomCloudProviderDataSource _customCloudProviderDataSource;

  String _activeProviderId;

  @override
  String get activeProvider => _activeProviderId;

  @override
  List<String> get supportedProviders =>
      List<String>.unmodifiable(CloudProviderCatalog.supportedProviders);

  @override
  void setProvider(String providerName) {
    final normalized = providerName.trim();
    _activeProviderId = CloudProviderCatalog.definitionFor(normalized) != null
        ? normalized
        : ActiveAiProvider.openAi.name;
  }

  @override
  String providerDisplayName([String? providerName]) {
    final requested = providerName == null ? _activeProviderId : providerName;
    return CloudProviderCatalog.definitionFor(requested)?.displayName ??
        requested;
  }

  @override
  String? validateProviderConfiguration([String? providerName]) {
    final requested = (providerName ?? _activeProviderId).trim();
    if (CloudProviderCatalog.definitionFor(requested) == null) {
      return 'Selected cloud AI provider is not supported. Please choose another provider in Settings.';
    }
    if (isProviderAvailable(requested)) {
      return null;
    }
    return 'Cloud AI provider not configured. Please add an API key or switch to Local AI mode.';
  }

  @override
  bool isProviderAvailable(String providerName) {
    final requested = providerName.trim();
    if (CloudProviderCatalog.isCustom(requested)) {
      return _customCloudProviderDataSource.isConfigured(requested);
    }

    final provider = _builtInProviderFromName(requested);
    if (provider == null) return false;
    return _isConfigured(provider);
  }

  @override
  Future<Either<Failure, AiResponse>> sendQuery(AiRequest request) async {
    return sendQueryWithProvider(_activeProviderId, request);
  }

  @override
  Future<Either<Failure, AiResponse>> sendQueryWithProvider(
    String providerName,
    AiRequest request,
  ) async {
    final requested = providerName.trim();
    CloudRoutingDiagnostics.attempt(
      providerId: requested,
      taskType: request.taskType,
    );

    try {
      final model = AiRequestModel.fromEntity(request);

      if (CloudProviderCatalog.isCustom(requested)) {
        final response = await _customCloudProviderDataSource.complete(
          requested,
          model,
        );
        CloudRoutingDiagnostics.success(
          providerId: requested,
          taskType: request.taskType,
        );
        return Right(response);
      }

      final provider = _builtInProviderFromName(requested);
      if (provider == null) {
        const failure = ServerFailure(
          'Selected cloud AI provider is not supported. Please choose another provider in Settings.',
        );
        CloudRoutingDiagnostics.failure(
          providerId: requested,
          taskType: request.taskType,
          failure: failure,
        );
        return const Left(failure);
      }

      // IMPORTANT: an explicit routed request must not mutate the global user
      // preference. Multiple executions may call different providers
      // concurrently; their routing decisions must remain isolated.
      final AiResponse response;

      switch (provider) {
        case ActiveAiProvider.openAi:
          response = await openAiDataSource.complete(model);
          break;
        case ActiveAiProvider.gemini:
          response = await geminiDataSource.complete(model);
          break;
        case ActiveAiProvider.claude:
          response = await claudeDataSource.complete(model);
          break;
        case ActiveAiProvider.grok:
          if (grokDataSource == null) {
            const failure = ServerFailure('Grok API key not configured');
            CloudRoutingDiagnostics.failure(
              providerId: requested,
              taskType: request.taskType,
              failure: failure,
            );
            return const Left(failure);
          }
          response = await grokDataSource!.complete(model);
          break;
        case ActiveAiProvider.copilot:
          if (copilotDataSource == null) {
            const failure = ServerFailure('Copilot API key not configured');
            CloudRoutingDiagnostics.failure(
              providerId: requested,
              taskType: request.taskType,
              failure: failure,
            );
            return const Left(failure);
          }
          response = await copilotDataSource!.complete(model);
          break;
      }

      CloudRoutingDiagnostics.success(
        providerId: requested,
        taskType: request.taskType,
      );
      return Right(response);
    } on NetworkException catch (e) {
      final failure = NetworkFailure(e.message);
      CloudRoutingDiagnostics.failure(
        providerId: requested,
        taskType: request.taskType,
        failure: failure,
      );
      return Left(failure);
    } on ServerException catch (e) {
      final failure = ServerFailure(e.message);
      CloudRoutingDiagnostics.failure(
        providerId: requested,
        taskType: request.taskType,
        failure: failure,
      );
      return Left(failure);
    } catch (e) {
      final failure = ServerFailure(e.toString());
      CloudRoutingDiagnostics.failure(
        providerId: requested,
        taskType: request.taskType,
        failure: failure,
      );
      return Left(failure);
    }
  }

  ActiveAiProvider? _builtInProviderFromName(String? providerName) {
    if (providerName == null) return null;
    for (final provider in ActiveAiProvider.values) {
      if (provider.name == providerName) {
        return provider;
      }
    }
    return null;
  }

  bool _isConfigured(ActiveAiProvider provider) {
    switch (provider) {
      case ActiveAiProvider.openAi:
        return openAiDataSource.isConfigured;
      case ActiveAiProvider.gemini:
        return geminiDataSource.isConfigured;
      case ActiveAiProvider.claude:
        return claudeDataSource.isConfigured;
      case ActiveAiProvider.grok:
        return grokDataSource?.isConfigured ?? false;
      case ActiveAiProvider.copilot:
        return copilotDataSource?.isConfigured ?? false;
    }
  }
}
