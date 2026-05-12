import 'package:ai_orchestrator/core/config/ai/ai_providers_config.dart';
import 'package:ai_orchestrator/core/config/ai/ai_roles.dart';

class AiModelConfig {
  const AiModelConfig({
    required this.id,
    required this.name,
    required this.provider,
    this.localPath,
    this.remoteUrl,
    this.enabled = true,
    this.description,
  });

  final String id;
  final String name;
  final AiProviderConfig provider;
  final String? localPath;
  final String? remoteUrl;
  final bool enabled;
  final String? description;

  AiModelConfig copyWith({
    String? id,
    String? name,
    AiProviderConfig? provider,
    String? localPath,
    String? remoteUrl,
    bool? enabled,
    String? description,
  }) {
    return AiModelConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      localPath: localPath ?? this.localPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      enabled: enabled ?? this.enabled,
      description: description ?? this.description,
    );
  }
}

class AiModelsConfig {
  const AiModelsConfig._();

  static const AiModelConfig orchestratorDefault = AiModelConfig(
    id: 'orchestrator_default',
    name: 'Orchestrator Default',
    provider: AiProviderConfig.local,
    description: 'Placeholder model for orchestration tasks.',
  );

  static const AiModelConfig geniusDefault = AiModelConfig(
    id: 'genius_default',
    name: 'Genius Default',
    provider: AiProviderConfig.gemini,
    description: 'Placeholder model for deeper reasoning tasks.',
  );

  static const AiModelConfig sageDefault = AiModelConfig(
    id: 'sage_default',
    name: 'Sage Default',
    provider: AiProviderConfig.openai,
    description: 'Placeholder model for summary and guidance tasks.',
  );

  static const List<AiModelConfig> models = <AiModelConfig>[
    orchestratorDefault,
    geniusDefault,
    sageDefault,
  ];

  static final Map<AiRoles, String> roleAssignments = <AiRoles, String>{
    AiRoles.orchestrator: orchestratorDefault.id,
    AiRoles.genius: geniusDefault.id,
    AiRoles.sage: sageDefault.id,
  };
}
