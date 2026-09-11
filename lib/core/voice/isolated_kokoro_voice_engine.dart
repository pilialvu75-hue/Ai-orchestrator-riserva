import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/audio_stream_player.dart';
import 'package:ai_orchestrator/core/voice/kokoro_assets.dart';
import 'package:ai_orchestrator/core/voice/pcm_validation.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Plain-data request passed to the background Kokoro isolate.
final class KokoroTtsGenerationRequest {
  const KokoroTtsGenerationRequest({
    required this.modelPath,
    required this.voicesPath,
    required this.tokensPath,
    required this.dataDir,
    required this.lang,
    required this.sid,
    required this.speed,
    required this.text,
  });

  final String modelPath;
  final String voicesPath;
  final String tokensPath;
  final String dataDir;
  final String lang;
  final int sid;
  final double speed;
  final String text;

  Map<String, Object?> toMessage() => <String, Object?>{
        'modelPath': modelPath,
        'voicesPath': voicesPath,
        'tokensPath': tokensPath,
        'dataDir': dataDir,
        'lang': lang,
        'sid': sid,
        'speed': speed,
        'text': text,
      };
}

final class KokoroTtsGeneratedAudio {
  const KokoroTtsGeneratedAudio({
    required this.samples,
    required this.sampleRate,
  });

  final Float32List samples;
  final int sampleRate;
}

typedef KokoroTtsGenerationRunner = Future<KokoroTtsGeneratedAudio> Function(
  KokoroTtsGenerationRequest request,
);

typedef KokoroAssetsProvider = Future<Map<String, String>?> Function();

abstract interface class TtsAudioSink {
  bool get isPlaying;

  void push(Float32List samples, int sampleRate);

  void stop();

  void dispose();
}

/// Audio sink for isolated Kokoro output.
///
/// [AudioStreamPlayer.stop] deliberately invalidates its current native
/// playback generation and leaves that instance stopped. Recreate the player
/// after every explicit stop so a later TTS request starts from a fresh native
/// lifecycle instead of inheriting a permanently stopped player.
final class AudioStreamTtsAudioSink implements TtsAudioSink {
  AudioStreamTtsAudioSink() : _player = AudioStreamPlayer();

  AudioStreamPlayer _player;
  bool _disposed = false;

  @override
  bool get isPlaying => !_disposed && _player.isPlaying;

  @override
  void push(Float32List samples, int sampleRate) {
    if (_disposed) return;
    _player.push(samples, sampleRate);
  }

  @override
  void stop() {
    if (_disposed) return;

    final previous = _player;
    previous.stop();
    previous.dispose();
    _player = AudioStreamPlayer();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _player.dispose();
  }
}

/// VoiceEngine decorator that keeps STT on the existing Sherpa engine while
/// running Kokoro model creation and synthesis outside the UI isolate.
///
/// sherpa_onnx 1.13.x exposes synchronous Dart TTS generation. Calling that
/// API from the UI isolate can therefore make Android report an ANR while a
/// long sentence is being synthesized. This decorator moves the complete
/// native TTS ownership lifecycle into a compute isolate:
///
///   init bindings -> create OfflineTts -> generate -> free OfflineTts
///
/// No native pointer crosses an isolate boundary. Only paths, generation
/// options and the generated Float32 PCM are transferred.
final class IsolatedKokoroVoiceEngine
    with RuntimeEventEmitter
    implements VoiceEngine {
  IsolatedKokoroVoiceEngine({
    required VoiceEngine delegate,
    String Function()? languageCode,
    KokoroTtsGenerationRunner? generationRunner,
    KokoroAssetsProvider? assetsProvider,
    TtsAudioSink? audioSink,
  })  : _delegate = delegate,
        _languageCode = languageCode ?? (() => 'it'),
        _generationRunner =
            generationRunner ?? runKokoroTtsGenerationInBackground,
        _assetsProvider = assetsProvider ?? KokoroAssets.verifiedPaths,
        _audioSink = audioSink ?? AudioStreamTtsAudioSink();

  static const String _tag = 'VOICE_ENGINE';

  final VoiceEngine _delegate;
  final String Function() _languageCode;
  final KokoroTtsGenerationRunner _generationRunner;
  final KokoroAssetsProvider _assetsProvider;
  final TtsAudioSink _audioSink;

  Future<KokoroTtsGeneratedAudio>? _generationInFlight;
  int _lifecycleGeneration = 0;
  bool _disposed = false;
  bool _requestBusy = false;

  @override
  bool get isListening => _delegate.isListening;

  @override
  bool get isSpeaking => _audioSink.isPlaying;

  @override
  Future<VoiceEngineStatus> inspect() async {
    final base = await _delegate.inspect();
    if (_disposed) return base;

    final assets = await _assetsProvider();
    return _withTtsAvailability(base, assets != null);
  }

  @override
  Future<VoiceEngineStatus> initialize() async {
    final base = await _delegate.initialize();
    if (_disposed) return base;

    final assets = await _assetsProvider();
    return _withTtsAvailability(base, assets != null);
  }

  VoiceEngineStatus _withTtsAvailability(
    VoiceEngineStatus base,
    bool available,
  ) {
    return base.copyWith(
      speakerOutputReady: available,
      offlineTtsAvailable: available,
    );
  }

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) {
    return _delegate.startListening(
      onResult: onResult,
      localeId: localeId,
    );
  }

  @override
  Future<void> stopListening() => _delegate.stopListening();

  @override
  Future<void> speak(String text) async {
    if (_disposed || text.trim().isEmpty) return;
    if (_requestBusy) {
      logEvent(_tag, '[TTS_WORKER_BUSY] generation=$_lifecycleGeneration');
      return;
    }
    // Acquire before the first await, including asset and delegate inspection.
    _requestBusy = true;
    final generation = _lifecycleGeneration;
    try {
      await _speakRequest(text.trim(), generation);
    } finally {
      _requestBusy = false;
    }
  }

  Future<void> _speakRequest(String sanitized, int generation) async {
    final assets = await _assetsProvider();
    if (_disposed || generation != _lifecycleGeneration) return;

    if (assets == null) {
      logEvent(
        _tag,
        '[TTS_BLOCKED] engine unavailable',
      );
      return;
    }

    final baseStatus = await _delegate.inspect();
    if (_disposed || generation != _lifecycleGeneration) return;

    final speed = baseStatus.speechRate;
    if (!speed.isFinite || speed <= 0) {
      logEvent(_tag, '[TTS_FAIL] invalid_speech_rate');
      throw StateError('Invalid TTS speech rate.');
    }

    final language = _languageCode().split(RegExp('[-_]')).first;
    final lang = const <String>['it', 'fr', 'en'].contains(language)
        ? language
        : 'en';

    // IDs belong to the pinned official Kokoro v1.0 bundle:
    // Sara (IT), Siwis (FR), Heart (EN).
    final sid = lang == 'it' ? 35 : (lang == 'fr' ? 30 : 3);

    final request = KokoroTtsGenerationRequest(
      modelPath: assets['model']!,
      voicesPath: assets['voices']!,
      tokensPath: assets['tokens']!,
      dataDir: assets['data']!,
      lang: lang,
      sid: sid,
      speed: speed,
      text: sanitized,
    );

    logEvent(
      _tag,
      '[TTS_GENERATE_BEGIN] family=kokoro lang=$lang sid=$sid '
      'speed=$speed chars=${sanitized.length}',
    );
    logEvent(
      _tag,
      '[TTS_WORKER_BEGIN] generation=$generation',
    );

    final future = _generationRunner(request);
    _generationInFlight = future;

    var failureReason = 'worker_failed';
    try {
      final audio = await future;

      if (_disposed || generation != _lifecycleGeneration) {
        logEvent(
          _tag,
          '[TTS_WORKER_DISCARDED] generation=$generation',
        );
        return;
      }

      failureReason = audio.samples.any((sample) => !sample.isFinite)
          ? 'non_finite_pcm' : 'invalid_pcm';
      validatePcm(audio.samples, audio.sampleRate);
      failureReason = 'playback_failed';

      logEvent(
        _tag,
        '[TTS_WORKER_READY] generation=$generation',
      );
      logEvent(
        _tag,
        '[TTS_AUDIO_READY] '
        'samples=${audio.samples.length} '
        'sampleRate=${audio.sampleRate}',
      );

      _audioSink.push(audio.samples, audio.sampleRate);
    } on Object {
      logEvent(
        _tag,
        '[TTS_FAIL] reason=$failureReason',
      );
      rethrow;
    } finally {
      if (identical(_generationInFlight, future)) {
        _generationInFlight = null;
      }
    }
  }

  @override
  Future<void> stopSpeaking() async {
    _lifecycleGeneration++;

    try {
      _audioSink.stop();
    } on Object {
      logEvent(_tag, '[TTS_STOP_WARN] isolated_audio_sink_failed');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;
    _lifecycleGeneration++;

    try {
      _audioSink.dispose();
    } on Object {
      logEvent(_tag, '[TTS_FREE_WARN] isolated_audio_sink_failed');
    }

    await _delegate.dispose();
  }
}

/// Runs one complete Kokoro synthesis request in a background isolate.
///
/// Each compute invocation owns its native Sherpa state. The native TTS
/// object is always freed in the same isolate that created it. This is more
/// conservative than transferring FFI-backed objects across isolates and is
/// intentionally chosen as the first ANR-containment step.
Future<KokoroTtsGeneratedAudio> runKokoroTtsGenerationInBackground(
  KokoroTtsGenerationRequest request,
) async {
  final result = await compute<Map<String, Object?>, Map<String, Object?>>(
    _generateKokoroTtsInIsolate,
    request.toMessage(),
    debugLabel: 'kokoro-tts-generation',
  );

  final samples = result['samples'];
  final sampleRate = result['sampleRate'];

  if (samples is! Float32List || sampleRate is! int) {
    throw StateError('Kokoro worker returned an invalid audio payload.');
  }

  return KokoroTtsGeneratedAudio(
    samples: samples,
    sampleRate: sampleRate,
  );
}

Map<String, Object?> _generateKokoroTtsInIsolate(
  Map<String, Object?> message,
) {
  final modelPath = message['modelPath'] as String;
  final voicesPath = message['voicesPath'] as String;
  final tokensPath = message['tokensPath'] as String;
  final dataDir = message['dataDir'] as String;
  final lang = message['lang'] as String;
  final sid = message['sid'] as int;
  final speed = message['speed'] as double;
  final text = message['text'] as String;

  sherpa_onnx.initBindings();

  final config = sherpa_onnx.OfflineTtsConfig(
    model: sherpa_onnx.OfflineTtsModelConfig(
      kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
        model: modelPath,
        voices: voicesPath,
        tokens: tokensPath,
        dataDir: dataDir,
        lang: 'it',
      ),
      numThreads: 1,
      debug: false,
      provider: 'cpu',
    ),
    maxNumSenetences: 1,
  );

  final tts = sherpa_onnx.OfflineTts(config);

  try {
    final audio = tts.generateWithConfig(
      text: text,
      config: sherpa_onnx.OfflineTtsGenerationConfig(
        sid: sid,
        speed: speed,
        extra: <String, Object>{'lang': lang},
      ),
    );

    return <String, Object?>{
      'samples': audio.samples,
      'sampleRate': audio.sampleRate,
    };
  } finally {
    tts.free();
  }
}
