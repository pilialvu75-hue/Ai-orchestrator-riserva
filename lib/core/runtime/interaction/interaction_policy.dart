/// Presentation channel used by the Assistant.
///
/// This contract is intentionally platform-neutral. Android, desktop, web,
/// Raspberry Pi or an automotive integration may select a mode, but the
/// conversational core does not inspect the operating system itself.
enum InteractionMode {
  text,
  voice,
  voiceWithScreen,
  voiceOnly,
}

/// Real-world interaction context that can further constrain presentation.
enum InteractionContext {
  general,
  home,
  driving,
}

/// Runtime presentation profile for one Assistant interaction.
///
/// Identity, memory, tools, model routing and cost policy deliberately do not
/// belong here. This object describes only how the answer should be presented.
class InteractionProfile {
  const InteractionProfile({
    this.mode = InteractionMode.text,
    this.context = InteractionContext.general,
  });

  final InteractionMode mode;
  final InteractionContext context;

  static const InteractionProfile text = InteractionProfile();

  bool get isVoice => mode != InteractionMode.text;

  bool get canRelyOnScreen =>
      mode == InteractionMode.text || mode == InteractionMode.voiceWithScreen;
}

/// Produces a small presentation-only system overlay from an explicit runtime
/// interaction profile.
///
/// The overlay is appended after the Assistant's base system prompt so every
/// execution backend keeps the same identity and conversation rules while only
/// adapting delivery to the current interaction channel/context.
abstract final class InteractionPolicy {
  static String presentationInstruction(InteractionProfile profile) {
    final rules = <String>[];

    switch (profile.mode) {
      case InteractionMode.text:
        break;
      case InteractionMode.voice:
        rules.addAll(const <String>[
          'Respond for spoken delivery using short, natural sentences.',
          'Avoid dense formatting, large tables, and long nested lists.',
        ]);
        break;
      case InteractionMode.voiceWithScreen:
        rules.addAll(const <String>[
          'Respond for spoken delivery using short, natural sentences.',
          'The screen may support the answer, but the spoken answer must contain the essential information.',
          'Avoid dense formatting unless the visual detail is genuinely useful.',
        ]);
        break;
      case InteractionMode.voiceOnly:
        rules.addAll(const <String>[
          'Respond for spoken delivery using short, natural sentences.',
          'Make the answer fully understandable without seeing a screen.',
          'Do not rely on visual references such as "above", "below", buttons, colors, or on-screen layout.',
          'Avoid dense formatting, tables, and long nested lists.',
        ]);
        break;
    }

    switch (profile.context) {
      case InteractionContext.general:
        break;
      case InteractionContext.home:
        rules.addAll(const <String>[
          'Prefer simple hands-free wording and brief confirmations.',
          'For a straightforward completed action, confirm the important result without unnecessary explanation.',
        ]);
        break;
      case InteractionContext.driving:
        rules.addAll(const <String>[
          'Minimize distraction: give the key point first and keep the response very short.',
          'Never require reading, typing, tapping, inspecting the screen, or other manual interaction while driving.',
          'If a request requires visual or manual interaction, defer that part until it can be done safely.',
        ]);
        break;
    }

    if (rules.isEmpty) return '';

    return <String>[
      'INTERACTION PRESENTATION',
      ...rules.map((rule) => '- $rule'),
    ].join('\n');
  }

  static String apply({
    required String baseSystemPrompt,
    required InteractionProfile profile,
  }) {
    final base = baseSystemPrompt.trim();
    final overlay = presentationInstruction(profile);

    if (overlay.isEmpty) return base;
    if (base.isEmpty) return overlay;
    return '$base\n\n$overlay';
  }
}
