import 'package:ai_orchestrator/core/config/ai/assistant_interaction_prompt_resolver.dart';
import 'package:ai_orchestrator/core/config/ai/assistant_system_prompt_service.dart';
import 'package:ai_orchestrator/core/config/ai/system_prompt_config.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/interaction/interaction_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AssistantInteractionPromptResolver> createResolver(
    Map<String, Object> initialValues,
  ) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final preferences = await SharedPreferences.getInstance();
    final config = ConfigRepository(PreferencesService(preferences));
    return AssistantInteractionPromptResolver(
      systemPromptService: AssistantSystemPromptService(
        configRepository: config,
      ),
    );
  }

  test('TEXT GENERAL preserves the conversational core exactly', () async {
    final resolver = await createResolver(const <String, Object>{});

    expect(
      resolver.resolve(
        incomingPrompt: SystemPromptConfig.defaultPrompt,
        profile: InteractionProfile.text,
      ),
      SystemPromptConfig.defaultPrompt,
    );
  });

  test('VOICE_WITH_SCREEN adds only presentation policy to same identity',
      () async {
    final resolver = await createResolver(const <String, Object>{});

    final result = resolver.resolve(
      incomingPrompt: SystemPromptConfig.defaultPrompt,
      profile: const InteractionProfile(
        mode: InteractionMode.voiceWithScreen,
        context: InteractionContext.general,
      ),
    );

    expect(result, startsWith(SystemPromptConfig.defaultPrompt));
    expect(result, contains('INTERACTION PRESENTATION'));
    expect(
      result,
      contains('Respond for spoken delivery using short, natural sentences.'),
    );
    expect(
      result,
      contains(
        'The screen may support the answer, but the spoken answer must contain the essential information.',
      ),
    );
  });

  test('stored custom identity is shared by text and voice', () async {
    const customPrompt = 'Custom assistant identity.';
    final resolver = await createResolver(<String, Object>{
      AppConstants.prefDirectionalPrompt: customPrompt,
    });

    final text = resolver.resolve(
      incomingPrompt: SystemPromptConfig.defaultPrompt,
      profile: InteractionProfile.text,
    );
    final voice = resolver.resolve(
      incomingPrompt: SystemPromptConfig.defaultPrompt,
      profile: const InteractionProfile(
        mode: InteractionMode.voiceWithScreen,
      ),
    );

    expect(text, customPrompt);
    expect(voice, startsWith('$customPrompt\n\nINTERACTION PRESENTATION'));
  });

  test('explicit specialized identity is preserved before voice overlay',
      () async {
    final resolver = await createResolver(<String, Object>{
      AppConstants.prefDirectionalPrompt: 'Stored assistant identity.',
    });

    final result = resolver.resolve(
      incomingPrompt: 'Specialized system prompt.',
      profile: const InteractionProfile(
        mode: InteractionMode.voiceOnly,
      ),
    );

    expect(result, startsWith('Specialized system prompt.'));
    expect(
      result,
      contains('Make the answer fully understandable without seeing a screen.'),
    );
    expect(result, isNot(contains('Stored assistant identity.')));
  });
}
