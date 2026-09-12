import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_text_normalizer.dart';

class VoiceOutputService {
  VoiceOutputService({
    required VoiceEngine engine,
    VoiceTextNormalizer normalizer = const VoiceTextNormalizer(),
  })  : _engine = engine,
        _normalizer = normalizer;

  final VoiceEngine _engine;
  final VoiceTextNormalizer _normalizer;

  VoiceEngineStatus? _lastStatus;

  /// Serializza tutte le operazioni TTS.
  ///
  /// È importante soprattutto durante il primo utilizzo, quando Piper viene
  /// inizializzato in modo lazy. Due tap ravvicinati non devono inizializzare
  /// o pilotare contemporaneamente lo stesso runtime nativo.
  Future<void> _operationQueue = Future<void>.value();

  /// Testo attualmente associato alla riproduzione.
  ///
  /// Viene utilizzato per implementare il comportamento toggle:
  ///
  /// - primo tap sul messaggio -> play
  /// - secondo tap sullo stesso messaggio -> stop
  /// - tap su un altro messaggio -> interrompe il precedente e riproduce
  ///   quello nuovo
  String? _activeNormalizedText;

  VoiceEngineStatus? get lastStatus => _lastStatus;

  bool get isSpeaking => _engine.isSpeaking;

  Future<bool> initialize() async {
    if (_lastStatus?.initialized == true) {
      return true;
    }

    _lastStatus = await _engine.initialize();

    return _lastStatus?.initialized == true;
  }

  /// Riproduce [text] usando il TTS.
  ///
  /// Questo metodo implementa deliberatamente una semantica "toggle":
  ///
  /// 1. se nulla sta parlando, avvia [text];
  /// 2. se lo stesso testo sta parlando, lo ferma;
  /// 3. se un altro testo sta parlando, lo ferma e avvia [text].
  ///
  /// Le operazioni vengono serializzate per evitare race condition durante
  /// l'inizializzazione lazy di Sherpa/Piper e durante tap rapidi consecutivi.
  Future<void> speak(String text) {
    RuntimeEventLog.instance.emit('[VOICE_OUTPUT_REQUEST] chars=${text.length}');
    final normalized =
        _normalizer.normalizeForTts(text);

    RuntimeEventLog.instance.emit('[VOICE_OUTPUT_NORMALIZED] chars=${normalized.length}');
    if (normalized.isEmpty) {
      return Future<void>.value();
    }

    return _enqueue(() async {
      RuntimeEventLog.instance.emit('[VOICE_OUTPUT_DEQUEUED]');
      final currentlySpeaking =
          _engine.isSpeaking;

      final isSameText =
          _activeNormalizedText ==
              normalized;

      // Secondo tap sullo stesso messaggio:
      // comportamento STOP.
      if (currentlySpeaking &&
          isSameText) {
        await _engine.stopSpeaking();

        _activeNormalizedText = null;

        await _refreshStatusSafely();

        return;
      }

      // Se sta parlando un altro messaggio,
      // interrompilo prima di iniziare il nuovo.
      if (currentlySpeaking) {
        await _engine.stopSpeaking();

        _activeNormalizedText = null;
      }

      /*
       * TTS intentionally remains lazy.
       *
       * SherpaOnnxVoiceEngine.speak() inizializza Piper soltanto quando
       * l'utente richiede effettivamente la lettura.
       *
       * Non chiamiamo initialize() qui perché initialize() riguarda anche
       * il percorso STT/microfono. L'altoparlante della chat deve poter
       * funzionare indipendentemente dalla Live e dal riconoscimento vocale.
       */
      RuntimeEventLog.instance.emit('[VOICE_OUTPUT_ENGINE_CALL]');
      await _engine.speak(normalized);
      RuntimeEventLog.instance.emit('[VOICE_OUTPUT_ENGINE_RETURNED]');

      // Impostiamo il testo attivo soltanto dopo che il comando speak è
      // stato consegnato correttamente al motore.
      _activeNormalizedText =
          normalized;

      /*
       * Una lazy initialization del TTS può avere aggiornato:
       *
       * - speakerOutputReady
       * - offlineTtsAvailable
       *
       * Il refresh dello stato non deve però trasformare un TTS riuscito
       * in un errore applicativo.
       */
      await _refreshStatusSafely();
    });
  }

  /// Interrompe sempre qualsiasi riproduzione TTS in corso.
  Future<void> stopSpeaking() {
    return _enqueue(() async {
      await _engine.stopSpeaking();

      _activeNormalizedText = null;

      await _refreshStatusSafely();
    });
  }

  Future<void> _refreshStatusSafely() async {
    try {
      RuntimeEventLog.instance.emit('[VOICE_OUTPUT_INSPECT_BEGIN]');
      _lastStatus =
          await _engine.inspect();
      RuntimeEventLog.instance.emit('[VOICE_OUTPUT_INSPECT_END]');
    } catch (_) {
      // Lo stato diagnostico è best-effort.
      // Non deve mai far fallire una richiesta TTS già eseguita.
    }
  }

  Future<void> _enqueue(
    Future<void> Function() operation,
  ) {
    final completer =
        Completer<void>();

    _operationQueue =
        _operationQueue.then<void>(
      (_) async {
        try {
          await operation();
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(
            error,
            stackTrace,
          );
        }
      },
      onError: (_, __) async {
        // Una precedente operazione fallita non deve bloccare
        // permanentemente la coda TTS.
        try {
          await operation();
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(
            error,
            stackTrace,
          );
        }
      },
    );

    return completer.future;
  }
}
