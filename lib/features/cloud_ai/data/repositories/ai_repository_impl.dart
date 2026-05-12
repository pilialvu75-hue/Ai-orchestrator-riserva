import 'package:dartz/dartz.dart';
import 'package:ai_orchestrator/core/error/exceptions.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_response.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/repositories/ai_repository.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/copilot_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/claude_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/gemini_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/grok_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/datasources/openai_datasource.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';

enum ActiveAiProvider { openAi, gemini, claude, grok, copilot }

class AiRepositoryImpl implements AiRepository {
  AiRepositoryImpl({
    required this.openAiDataSource,
    required this.geminiDataSource,
    required this.claudeDataSource,
    this.grokDataSource,
    this.copilotDataSource,
    this.activeAiProvider = ActiveAiProvider.openAi,
  });

  final OpenAiDataSource openAiDataSource;
  final GeminiDataSource geminiDataSource;
  final ClaudeDataSource claudeDataSource;
  final GrokDataSource? grokDataSource;
  final CopilotDataSource? copilotDataSource;
  ActiveAiProvider activeAiProvider;

  @override
  String get activeProvider => activeAiProvider.name;

  @override
  List<String> get supportedProviders =>
      List<String>.unmodifiable(CloudProviderCatalog.supportedProviders);

  @override
  void setProvider(String providerName) {
    activeAiProvider = _providerFromName(providerName) ?? ActiveAiProvider.openAi;
  }

  @override
  String providerDisplayName([String? providerName]) {
    switch (_providerFromName(providerName) ?? activeAiProvider) {
      case ActiveAiProvider.openAi:
        return 'OpenAI';
      case ActiveAiProvider.gemini:
        return 'Gemini';
      case ActiveAiProvider.claude:
        return 'Claude';
      case ActiveAiProvider.grok:
        return 'Grok';
      case ActiveAiProvider.copilot:
        return 'GitHub Copilot';
    }
  }

  @override
  String? validateProviderConfiguration([String? providerName]) {
    final provider = _providerFromName(providerName);
    if (provider == null) {
      return 'Selected cloud AI provider is not supported. Please choose another provider in Settings.';
    }
    if (_isConfigured(provider)) {
      return null;
    }
    return 'Cloud AI provider not configured. Please add an API key or switch to Local AI mode.';
  }

  @override
  bool isProviderAvailable(String providerName) {
    final provider = _providerFromName(providerName);
    if (provider == null) return false;
    return _isConfigured(provider);
  }

  @override
  Future<Either<Failure, AiResponse>> sendQuery(AiRequest request) async {
    return sendQueryWithProvider(activeAiProvider.name, request);
  }

  @override
  Future<Either<Failure, AiResponse>> sendQueryWithProvider(
    String providerName,
    AiRequest request,
  ) async {
    try {
      final provider = _providerFromName(providerName);
      if (provider == null) {
        return const Left(
          ServerFailure(
            'Selected cloud AI provider is not supported. Please choose another provider in Settings.',
          ),
        );
      }
      activeAiProvider = provider;
      final model = AiRequestModel.fromEntity(request);
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
            return const Left(ServerFailure('Grok API key not configured'));
          }
          response = await grokDataSource!.complete(model);
          break;
        case ActiveAiProvider.copilot:
          if (copilotDataSource == null) {
            return const Left(ServerFailure('Copilot API key not configured'));
          }
          response = await copilotDataSource!.complete(model);
          break;
      }
      return Right(response);
    } on NetworkException catch (e) {
      return Left(NetworkFailure(e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(e.message));
    } catch (e) {
      return Left(ServerFailure(e.toString()));
    }
  }

  ActiveAiProvider? _providerFromName(String? providerName) {
    if (providerName == null) return activeAiProvider;
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
