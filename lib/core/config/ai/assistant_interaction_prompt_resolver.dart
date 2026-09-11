import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/runtime/interaction/interaction_policy.dart';

/// Single composition boundary for Assistant identity + presentation policy.
///
/// The user's stored/custom system prompt remains the base identity. Interaction
/// policy is applied at request time and is never persisted into that prompt.
class AssistantInteractionPromptResolver {
  const AssistantInteractionPromptResolver({
    required AssistantSystemPromptService systemPromptService,
  }) : _systemPromptService = systemPromptService;

  final AssistantSystemPromptService _systemPromptService;

  String resolve({
    String? incomingPrompt,
    InteractionProfile profile = InteractionProfile.text,
  }) {
    final basePrompt = _systemPromptService.resolveForIncoming(incomingPrompt);
    return InteractionPolicy.apply(
      baseSystemPrompt: basePrompt,
      profile: profile,
    );
  }
}
