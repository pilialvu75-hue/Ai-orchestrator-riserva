import 'dart:collection';

import 'package:ai_orchestrator/core/config/ai/ai_model.dart';
import 'package:ai_orchestrator/core/config/ai/ai_role.dart';

/// Central in-memory registry for AI model configuration.
class AiRegistry {
  final Map<String, AiModel> _modelsById = <String, AiModel>{};
  final Map<AiRole, List<String>> _roleModelIds = <AiRole, List<String>>{};

  /// Registers or replaces a model definition.
  void registerModel(AiModel model) {
    _modelsById[model.id] = model;
  }

  /// Returns all currently registered models.
  List<AiModel> get allModels => _modelsById.values.toList(growable: false);

  /// Returns model definitions assigned to [role].
  List<AiModel> getModelsByRole(AiRole role) {
    final ids = _roleModelIds[role] ?? const <String>[];
    return ids
        .map((id) => _modelsById[id])
        .whereType<AiModel>()
        .toList(growable: false);
  }

  /// Assigns an already-registered model to a role.
  void assignModelToRole(AiRole role, String modelId) {
    if (!_modelsById.containsKey(modelId)) {
      throw ArgumentError.value(
        modelId,
        'modelId',
        'Model must be registered before role assignment.',
      );
    }

    final assignments = _roleModelIds.putIfAbsent(role, () => <String>[]);
    if (!assignments.contains(modelId)) {
      assignments.add(modelId);
    }
  }

  /// Returns a model by its ID when available.
  AiModel? getModelById(String modelId) => _modelsById[modelId];

  /// Returns the first assigned model for [role], if any.
  AiModel? getPrimaryModelForRole(AiRole role) {
    final models = getModelsByRole(role);
    return models.isEmpty ? null : models.first;
  }

  /// Read-only snapshot of role-to-model assignments.
  Map<AiRole, List<String>> get roleAssignments => UnmodifiableMapView(
        _roleModelIds.map(
          (role, ids) => MapEntry(role, List<String>.unmodifiable(ids)),
        ),
      );

  // TODO(future): support priorities/fallback order per role.
  // TODO(future): persist and hydrate assignments via config storage.
  // TODO(future): expose UI-friendly options for dropdown model selectors.
}
