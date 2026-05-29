import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';

enum LlmRole {
  hannibalCoordinator,
}

class LlmRoleAssignmentService {
  LlmRoleAssignmentService({required ConfigRepository configRepository})
      : _configRepository = configRepository;

  final ConfigRepository _configRepository;

  Future<String?> getAssignedModelId(LlmRole role) async {
    final stored = _configRepository.getString(_storageKey(role))?.trim();
    if (stored == null || stored.isEmpty) return null;
    return stored;
  }

  Future<void> assignModelId({
    required LlmRole role,
    required String modelId,
  }) async {
    final normalized = modelId.trim();
    if (normalized.isEmpty) {
      await _configRepository.remove(_storageKey(role));
      return;
    }
    await _configRepository.setString(_storageKey(role), normalized);
  }

  String _storageKey(LlmRole role) =>
      '${AppConstants.prefLlmRoleBindingPrefix}${role.name}';
}
