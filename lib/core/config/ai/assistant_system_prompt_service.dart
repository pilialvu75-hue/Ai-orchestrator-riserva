import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';

/// Resolves the Assistant's user-configurable system prompt without leaking
/// storage concerns into the chat UI or the inference providers.
///
/// The bundled conversational core remains the fallback. A stored custom prompt
/// replaces that core for normal Assistant chat, while callers that provide an
/// explicit specialized prompt keep full control.
class AssistantSystemPromptService {
  const AssistantSystemPromptService({
    required ConfigRepository configRepository,
  }) : _configRepository = configRepository;

  final ConfigRepository _configRepository;

  String get currentPrompt {
    final stored = _configRepository
        .getString(AppConstants.prefDirectionalPrompt)
        ?.trim();

    if (stored == null || stored.isEmpty) {
      return SystemPromptConfig.defaultPrompt;
    }

    if (SystemPromptConfig.isBundledDefault(stored)) {
      return SystemPromptConfig.defaultPrompt;
    }

    return stored;
  }

  /// Applies the configured Assistant prompt only to ordinary Assistant chat.
  ///
  /// Any bundled stock prompt (current or historical), null or blank marks an
  /// ordinary Assistant request. Any other prompt is an explicit specialization
  /// and is preserved unchanged.
  String resolveForIncoming(String? incomingPrompt) {
    final incoming = incomingPrompt?.trim();

    if (incoming == null ||
        incoming.isEmpty ||
        SystemPromptConfig.isBundledDefault(incoming)) {
      return currentPrompt;
    }

    return incoming;
  }

  /// Upgrades only exact historical stock prompts. User-authored prompts are
  /// never rewritten merely because a new bundled default ships with the app.
  Future<bool> migrateLegacyDefaultIfNeeded() async {
    final stored = _configRepository
        .getString(AppConstants.prefDirectionalPrompt)
        ?.trim();

    if (stored == null ||
        stored.isEmpty ||
        stored == SystemPromptConfig.defaultPrompt ||
        !SystemPromptConfig.isBundledDefault(stored)) {
      return false;
    }

    await _configRepository.setString(
      AppConstants.prefDirectionalPrompt,
      SystemPromptConfig.defaultPrompt,
    );
    return true;
  }
}
