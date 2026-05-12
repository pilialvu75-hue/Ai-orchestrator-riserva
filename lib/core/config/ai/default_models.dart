import 'package:ai_orchestrator/core/config/ai/ai_models_config.dart';
import 'package:ai_orchestrator/core/config/ai/ai_roles.dart';

/// Backward-compatible default model catalog.
class DefaultModels {
  const DefaultModels._();

  static const AiModelConfig orchestratorDefault =
      AiModelsConfig.orchestratorDefault;
  static const AiModelConfig geniusDefault = AiModelsConfig.geniusDefault;
  static const AiModelConfig sageDefault = AiModelsConfig.sageDefault;

  static const List<AiModelConfig> models = AiModelsConfig.models;

  static final Map<AiRoles, String> roleAssignments =
      AiModelsConfig.roleAssignments;
}
