import 'package:ai_orchestrator/core/runtime/interaction/interaction_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InteractionPolicy', () {
    test('TEXT GENERAL leaves the base conversational identity unchanged', () {
      const base = 'BASE ASSISTANT IDENTITY';

      expect(
        InteractionPolicy.apply(
          baseSystemPrompt: base,
          profile: InteractionProfile.text,
        ),
        base,
      );
      expect(
        InteractionPolicy.presentationInstruction(InteractionProfile.text),
        isEmpty,
      );
    });

    test('VOICE changes presentation without replacing base identity', () {
      const base = 'BASE ASSISTANT IDENTITY';
      const profile = InteractionProfile(mode: InteractionMode.voice);

      final result = InteractionPolicy.apply(
        baseSystemPrompt: base,
        profile: profile,
      );

      expect(result, startsWith(base));
      expect(result, contains('short, natural sentences'));
      expect(result, contains('Avoid dense formatting'));
    });

    test('VOICE_WITH_SCREEN keeps spoken answer independently useful', () {
      const profile = InteractionProfile(
        mode: InteractionMode.voiceWithScreen,
      );

      final overlay = InteractionPolicy.presentationInstruction(profile);

      expect(overlay, contains('screen may support the answer'));
      expect(overlay, contains('spoken answer must contain the essential information'));
      expect(profile.canRelyOnScreen, isTrue);
    });

    test('VOICE_ONLY never relies on visual presentation', () {
      const profile = InteractionProfile(mode: InteractionMode.voiceOnly);

      final overlay = InteractionPolicy.presentationInstruction(profile);

      expect(overlay, contains('fully understandable without seeing a screen'));
      expect(overlay, contains('Do not rely on visual references'));
      expect(profile.isVoice, isTrue);
      expect(profile.canRelyOnScreen, isFalse);
    });

    test('HOME adds hands-free confirmation behavior', () {
      const profile = InteractionProfile(
        mode: InteractionMode.voiceOnly,
        context: InteractionContext.home,
      );

      final overlay = InteractionPolicy.presentationInstruction(profile);

      expect(overlay, contains('hands-free wording'));
      expect(overlay, contains('brief confirmations'));
    });

    test('DRIVING dominates presentation with low-distraction constraints', () {
      const profile = InteractionProfile(
        mode: InteractionMode.voiceWithScreen,
        context: InteractionContext.driving,
      );

      final overlay = InteractionPolicy.presentationInstruction(profile);

      expect(overlay, contains('Minimize distraction'));
      expect(overlay, contains('key point first'));
      expect(overlay, contains('Never require reading, typing, tapping'));
      expect(overlay, contains('defer that part until it can be done safely'));
    });

    test('empty base still yields only the requested presentation overlay', () {
      const profile = InteractionProfile(mode: InteractionMode.voiceOnly);

      final result = InteractionPolicy.apply(
        baseSystemPrompt: '   ',
        profile: profile,
      );

      expect(result, startsWith('INTERACTION PRESENTATION'));
      expect(result, isNot(contains('BASE ASSISTANT IDENTITY')));
    });
  });
}
