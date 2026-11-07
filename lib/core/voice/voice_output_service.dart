import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
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
  int _requestGeneration = 0;

  VoiceEngineStatus? get lastStatus => _lastStatus;

  bool get isSpeaking => _engine.isSpeaking;

  ReadAloudVoiceEngine? get _transport {
    final engine = _engine;
    if (engine is! ReadAloudVoiceEngine) return null;
    final transport = engine as ReadAloudVoiceEngine;
    return transport.supportsRealReadAloudControls ? transport : null;
  }

  bool get supportsRealReadAloudControls => _transport != null;

  ReadAloudSnapshot get readAloudSnapshot =>
      _transport?.readAloudSnapshot ?? const ReadAloudSnapshot();

  Future<ReadAloudSnapshot> refreshReadAloud() async =>
      await _transport?.refreshReadAloud() ?? const ReadAloudSnapshot();

  /// Rebuilds the PCM timeline on an explicit new Play request and starts
  /// from the last measured position when the Android engine supports it.
  /// Falls back to a normal read on non-Android engines.
  Future<void> speakFromPosition(String text, Duration position) {
    final normalized = _normalizer.normalizeForTts(text);
    if (normalized.isEmpty) return Future<void>.value();
    if (position <= Duration.zero ||
        !supportsRealReadAloudControls ||
        _engine is! ReadAloudResumeTarget) {
      return speak(text);
    }
    final token = ++_requestGeneration;
    return _speakPcm(normalized, token, resumeFrom: position);
  }

  Future<void> pauseReadAloud() async {
    await _transport?.pauseReadAloud();
  }

  Future<void> resumeReadAloud() async {
    await _transport?.resumeReadAloud();
  }

  Future<void> skipReadAloud(Duration delta) async {
    await _transport?.skipReadAloud(delta);
  }

  Future<void> seekReadAloud(Duration position) async {
    await _transport?.seekReadAloud(position);
  }


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
    final normalized =
        _normalizer.normalizeForTts(text);

    if (normalized.isEmpty) {
      return Future<void>.value();
    }

    final requestToken = ++_requestGeneration;
    if (supportsRealReadAloudControls) {
      // A PCM synthesis can take seconds while producing the first phrase.
      // Do not place the next user tap behind its entire awaited speak().
      // The isolated Kokoro engine safely drains a cancelled worker before
      // admitting a new synthesis, without replaying its stale PCM.
      return _speakPcm(normalized, requestToken);
    }
    return _enqueue(() async {
      if (requestToken != _requestGeneration) return;
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
      await _engine.speak(normalized);
      if (requestToken != _requestGeneration) return;

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

  /// Preemptible user-initiated PCM read-aloud: latest tap wins.
  ///
  /// The former _operationQueue awaited all Kokoro phrases, so switching to
  /// another chat message could be delayed until that entire synthesis ended.
  /// Non-PCM engines still use the original serial queue above.
  Future<void> _speakPcm(String normalized, int token,
      {Duration resumeFrom = Duration.zero}) async {
    if (token != _requestGeneration) return;
    final previous = _activeNormalizedText;
    if (previous != null || _engine.isSpeaking) {
      // A previous media session may have ended following permanent audio
      // focus loss (e.g. YouTube). Re-tapping that message must start a new
      // session, not turn into an invisible second Stop.
      var wasActive = _engine.isSpeaking;
      if (previous == normalized) {
        final snapshot = await refreshReadAloud();
        if (token != _requestGeneration) return;
        wasActive = wasActive || snapshot.active;
      }
      await _engine.stopSpeaking();
      if (token != _requestGeneration) return;
      _activeNormalizedText = null;
      if (previous == normalized && wasActive) {
        await _refreshStatusSafely();
        return;
      }
    }
    if (token != _requestGeneration) return;

    // Claim the message before generation: before the first PCM frame,
    // isSpeaking can still be false while the worker is genuinely busy.
    _activeNormalizedText = normalized;
    try {
      // Set AFTER any old session's Stop. No bookmark can leak into a
      // superseded request and the engine still owns its native worker.
      if (resumeFrom > Duration.zero && _engine is ReadAloudResumeTarget) {
        (_engine as ReadAloudResumeTarget)
            .setNextReadAloudPosition(resumeFrom);
      }
      await _engine.speak(normalized);
      if (token == _requestGeneration) await _refreshStatusSafely();
    } catch (_) {
      if (token == _requestGeneration) _activeNormalizedText = null;
      rethrow;
    }
  }

  /// Interrompe sempre qualsiasi riproduzione TTS in corso.
  Future<void> stopSpeaking() async {
    final token = ++_requestGeneration;
    if (supportsRealReadAloudControls) {
      // Do not wait for synthesis of every phrase in a long answer.
      await _engine.stopSpeaking();
      // A new Play may have started while native Stop was awaiting its
      // platform-channel acknowledgment. Never clear the newer selection.
      if (token == _requestGeneration) {
        _activeNormalizedText = null;
        await _refreshStatusSafely();
      }
      return;
    }
    await _enqueue(() async {
      await _engine.stopSpeaking();
      _activeNormalizedText = null;
      await _refreshStatusSafely();
    });
  }

  Future<void> _refreshStatusSafely() async {
    try {
      _lastStatus =
          await _engine.inspect();
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
