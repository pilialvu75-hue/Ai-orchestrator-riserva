// The project deliberately keeps Flutter 3.22 / Dart 3.4 as its compatibility
// floor. This Web-only adapter therefore still uses the legacy browser
// interop libraries that are available across that baseline. Keep the
// deprecation suppression scoped to this file; native builds never import it.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;

/// Thin Web-only adapter around the browser Speech Recognition and Speech
/// Synthesis APIs. It intentionally stays outside the native Sherpa/Kokoro
/// stack: Aivexus Web uses the browser capability when present, while native
/// platforms keep their offline voice engines unchanged.
final class WorkshopWebBrowserAudio {
  Object? _recognition;
  bool _isListening = false;

  bool get isListening => _isListening;

  bool get canDictate =>
      _readWindowProperty('SpeechRecognition') != null ||
      _readWindowProperty('webkitSpeechRecognition') != null;

  bool get canSpeak =>
      _readWindowProperty('speechSynthesis') != null &&
      _readWindowProperty('SpeechSynthesisUtterance') != null;

  String get _language {
    final language = html.window.navigator.language;
    return language.trim().isEmpty ? 'it-IT' : language;
  }

  Future<bool> startDictation({
    required void Function(String text, bool isFinal) onResult,
    void Function(bool listening)? onStateChanged,
    void Function(String message)? onError,
  }) async {
    if (_isListening) return true;

    final constructor = _readWindowProperty('SpeechRecognition') ??
        _readWindowProperty('webkitSpeechRecognition');
    if (constructor == null) {
      onError?.call('La dettatura vocale non è supportata da questo browser.');
      return false;
    }

    try {
      final recognition =
          js_util.callConstructor<Object>(constructor, const <Object?>[]);
      _recognition = recognition;

      js_util.setProperty(recognition, 'lang', _language);
      js_util.setProperty(recognition, 'continuous', false);
      js_util.setProperty(recognition, 'interimResults', true);
      js_util.setProperty(recognition, 'maxAlternatives', 1);

      js_util.setProperty(
        recognition,
        'onresult',
        js.allowInterop((dynamic event) {
          final results = _readProperty(event, 'results');
          if (results == null) return;

          final resultIndex =
              (_readProperty(event, 'resultIndex') as num?)?.toInt() ?? 0;
          final length =
              (_readProperty(results, 'length') as num?)?.toInt() ?? 0;

          for (var index = resultIndex; index < length; index++) {
            final result = _readProperty(results, index.toString());
            if (result == null) continue;
            final alternative = _readProperty(result, '0');
            if (alternative == null) continue;

            final transcript =
                (_readProperty(alternative, 'transcript') as String?)?.trim();
            if (transcript == null || transcript.isEmpty) continue;

            final isFinal = _readProperty(result, 'isFinal') == true;
            onResult(transcript, isFinal);
          }
        }),
      );

      js_util.setProperty(
        recognition,
        'onerror',
        js.allowInterop((dynamic event) {
          final raw = _readProperty(event, 'error')?.toString().trim();
          if (raw != null && raw.isNotEmpty && raw != 'no-speech') {
            onError?.call('Dettatura non disponibile: $raw');
          }
        }),
      );

      js_util.setProperty(
        recognition,
        'onend',
        js.allowInterop((dynamic _) {
          _recognition = null;
          _isListening = false;
          onStateChanged?.call(false);
        }),
      );

      js_util.callMethod<void>(recognition, 'start', const <Object?>[]);
      _isListening = true;
      onStateChanged?.call(true);
      return true;
    } catch (_) {
      _recognition = null;
      _isListening = false;
      onStateChanged?.call(false);
      onError?.call(
        'Impossibile avviare il microfono. Controlla il permesso del browser.',
      );
      return false;
    }
  }

  Future<void> stopDictation() async {
    final recognition = _recognition;
    if (recognition != null) {
      try {
        js_util.callMethod<void>(recognition, 'stop', const <Object?>[]);
      } catch (_) {
        // The browser may already have ended the recognition session.
      }
    }
    _recognition = null;
    _isListening = false;
  }

  void speak(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || !canSpeak) return;

    final synthesis = _readWindowProperty('speechSynthesis');
    final constructor = _readWindowProperty('SpeechSynthesisUtterance');
    if (synthesis == null || constructor == null) return;

    try {
      final utterance = js_util.callConstructor<Object>(
        constructor,
        <Object?>[normalized],
      );
      js_util.setProperty(utterance, 'lang', _language);
      js_util.setProperty(utterance, 'rate', 1.0);
      js_util.callMethod<void>(synthesis, 'cancel', const <Object?>[]);
      js_util.callMethod<void>(synthesis, 'speak', <Object?>[utterance]);
    } catch (_) {
      // Audio output is a convenience. Failure must never break the chat.
    }
  }

  void stopSpeaking() {
    final synthesis = _readWindowProperty('speechSynthesis');
    if (synthesis == null) return;
    try {
      js_util.callMethod<void>(synthesis, 'cancel', const <Object?>[]);
    } catch (_) {
      // Ignore browsers that expose a partial SpeechSynthesis implementation.
    }
  }

  Object? _readWindowProperty(String name) {
    if (!js_util.hasProperty(html.window, name)) return null;
    return js_util.getProperty<Object?>(html.window, name);
  }

  static Object? _readProperty(dynamic object, String name) {
    if (object == null) return null;
    try {
      return js_util.getProperty<Object?>(object as Object, name);
    } catch (_) {
      return null;
    }
  }
}
