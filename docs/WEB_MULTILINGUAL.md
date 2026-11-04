# Aivexus Web — multilingual UI (IT / FR / EN / ES)

This is an independent **Web-only** locale preference. It does not read or
change native AI Orchestrator settings, credential storage or cloud provider
routes.

## Runtime

- The header of `lib/web_main.dart` contains a manual language selector.
- Italian, French, English and Spanish are offered by name.
- `WorkshopWebLanguage` loads the browser locale on first use and persists
  the user's chosen language via the dedicated
  `aivexus.web.ui.language.v1` preference key.
- Switching languages updates the Status/Workshop navigation, Web capability
  cards, project controls and most proposal labels immediately.
- Existing project titles, descriptions, generated proposals, saved phase
  identifiers and chat records remain **unaltered**. Old project records can
  be reopened in the selected language; their own free text is never silently
  translated or re-sent to a provider.
- The Web caller explicitly configures `WorkshopChatController` with its
  preferred response language. The instructions preserve the exact
  `PROPOSAL:` and `CLARIFY:` protocol markers, regardless of display
  language, so proposal approval remains compatible with the existing model
  parser. This is a prompt-level preference, not a guarantee that every
  upstream model will obey; test with real authorized routes before declaring
  end-to-end multilingual quality.

## Tests and limitations

- `workshop_web_language_test.dart` checks loading, persistence, language
  switching and the Status card translations without external services.
- Some diagnostic messages and older free-text status descriptions are
  deliberately preserved in their stored language pending a separate
  copy review. They must not be mistaken for newly generated translations.
- No translation service, new paid API or browser-to-native runtime bridge
  is introduced.

This feature can ship independently of the separate Self-Test Cloud PR.
