// The project deliberately keeps Flutter 3.22 / Dart 3.4 as its compatibility
// floor. This Web-only adapter therefore retains dart:js, which is available
// across that baseline and on the newer CI SDKs. Keep the deprecation
// suppression scoped to this file; native builds never import it.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js' as js;

/// Thin Web-only adapter around the browser Speech Recognition and Speech
/// Synthesis APIs. It intentionally stays outside the native Sherpa/Kokoro
/// stack: Aivexus Web uses the browser capability when present, while native
/// platforms keep their offline voice engines unchanged.
final class WorkshopWebBrowserAudio {
  js.JsObject? _recognition;
  bool _isListening = false;

  bool get isListening => _isListening;

  bool get canDictate =>
      js.context.hasProperty('SpeechRecognition') ||
      js.context.hasProperty('webkitSpeechRecognition');

  bool get canSpeak =>
      js.context.hasProperty('speechSynthesis') &&
      js.context.hasProperty('SpeechSynthesisUtterance');

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

    final rawConstructor = js.context['SpeechRecognition'] ??
        js.context['webkitSpeechRecognition'];
    if (rawConstructor is! js.JsFunction) {
      onError?.call('La dettatura vocale non è supportata da questo browser.');
      return false;
    }

    try {
      final recognition = js.JsObject(rawConstructor);
      _recognition = recognition;

      recognition['lang'] = _language;
      recognition['continuous'] = false;
      recognition['interimResults'] = true;
      recognition['maxAlternatives'] = 1;

      recognition['onresult'] = (dynamic event) {
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
      };

      recognition['onerror'] = (dynamic event) {
        final raw = _readProperty(event, 'error')?.toString().trim();
        if (raw != null && raw.isNotEmpty && raw != 'no-speech') {
          onError?.call('Dettatura non disponibile: $raw');
        }
      };

      recognition['onend'] = (dynamic _) {
        _recognition = null;
        _isListening = false;
        onStateChanged?.call(false);
      };

      recognition.callMethod('start');
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
        recognition.callMethod('stop');
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

    final synthesis = _asJsObject(js.context['speechSynthesis']);
    final rawConstructor = js.context['SpeechSynthesisUtterance'];
    if (synthesis == null || rawConstructor is! js.JsFunction) return;

    try {
      final utterance = js.JsObject(rawConstructor, <Object?>[normalized]);
      utterance['lang'] = _language;
      utterance['rate'] = 1.0;
      synthesis.callMethod('cancel');
      synthesis.callMethod('speak', <Object?>[utterance]);
    } catch (_) {
      // Audio output is a convenience. Failure must never break the chat.
    }
  }

  void stopSpeaking() {
    final synthesis = _asJsObject(js.context['speechSynthesis']);
    if (synthesis == null) return;
    try {
      synthesis.callMethod('cancel');
    } catch (_) {
      // Ignore browsers that expose a partial SpeechSynthesis implementation.
    }
  }

  static js.JsObject? _asJsObject(dynamic value) {
    if (value is js.JsObject) return value;
    if (value == null) return null;
    try {
      return js.JsObject.fromBrowserObject(value as Object);
    } catch (_) {
      return null;
    }
  }

  static Object? _readProperty(dynamic object, String name) {
    final target = _asJsObject(object);
    if (target == null) return null;
    try {
      return target[name] as Object?;
    } catch (_) {
      return null;
    }
  }
}
