import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ai_orchestrator/core/voice/audio_stream_player.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

/// Direct Dart-SDK voice engine using the `sherpa_onnx` package for offline
/// STT and TTS, and `record` for low-level PCM microphone streaming.
///
/// Architecture
/// ─────────────
/// 1. [initialize] binds the native ONNX libraries once, constructs
///    [sherpa_onnx.OnlineRecognizer] (streaming transducer ASR) and
///    [sherpa_onnx.OfflineTts] (VITS TTS).  Every critical step emits a
///    forensic checkpoint to [RuntimeEventLog] so that failures are surfaced
///    directly in the diagnostics console / settings menu.
/// 2. [startListening] opens an [AudioRecorder] stream at 16 kHz mono PCM-16
///    and feeds each [Uint8List] chunk – converted to [Float32List] via the
///    standard int16/32768 normalisation – to [sherpa_onnx.OnlineStream].
/// 3. [speak] calls [sherpa_onnx.OfflineTts.generate] synchronously on the
///    caller's zone.  The resulting [Float32List] samples are immediately
///    enqueued on [_audioPlayer] which streams them to the device speaker
///    via [mp_audio_stream] at low latency.
/// 4. [stopSpeaking] cancels any in-progress playback and flushes the
///    hardware ring-buffer for immediate barge-in response.
/// 5. [dispose] shuts down all native streams and frees ONNX handles in the
///    correct order to prevent memory leaks or audio-thread stalls.
///
/// Guardrails
/// ──────────
/// • All model-path params use `??` coalescence so missing paths produce a
///   clear [VoiceEngineStatus.unsupported] with a readable [details] string
///   instead of a null-dereference crash.
/// • [_forensicPrint] emits synchronous `print` checkpoints immediately before
///   and after every hardware-adjacent native call to capture silent hardware
///   crashes that `debugPrint` (async-buffered) may not surface.
class SherpaOnnxVoiceEngine with RuntimeEventEmitter implements VoiceEngine {
  SherpaOnnxVoiceEngine({
    VoiceModelPaths? modelPaths,
  }) : _modelPaths = modelPaths ?? const VoiceModelPaths();

  static const String _tag = 'VOICE_ENGINE';

  final VoiceModelPaths _modelPaths;
  final RuntimeModelPathResolver _pathResolver = const RuntimeModelPathResolver();

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _asrStream;
  sherpa_onnx.OfflineTts? _tts;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSubscription;

  VoiceEngineStatus _status = VoiceEngineStatus.unsupported();
  bool _isListening = false;
  bool _initialized = false;

  // Phase 2: serial low-latency audio output player.
  final AudioStreamPlayer _audioPlayer = AudioStreamPlayer();

  // TTS output is stored per-generation for diagnostics / callers that read
  // the raw samples directly (e.g. tests, subtitle rendering).
  Float32List? _pendingTtsSamples;
  int _pendingTtsSampleRate = 22050;

  @override
  bool get isListening => _isListening;

  /// `true` while audio samples are being played or queued for playback.
  ///
  /// Delegates to [_audioPlayer.isPlaying] so the flag correctly reflects
  /// the actual hardware state rather than a simple bool toggle.
  @override
  bool get isSpeaking => _audioPlayer.isPlaying;

  Float32List? get pendingTtsSamples => _pendingTtsSamples;
  int get pendingTtsSampleRate => _pendingTtsSampleRate;

  // ── Forensic print helper ─────────────────────────────────────────────────

  /// Synchronous forensic print emitted immediately before/after hardware-
  /// adjacent native calls (mic stream open, ONNX binding).  Uses `print`
  /// rather than `debugPrint` because `debugPrint` is async-buffered and
  /// may be dropped when the hardware thread crashes before the Dart event
  /// loop resumes.
  static void _forensicPrint(String message) {
    // ignore: avoid_print
    print(message);
  }

  static bool _isReadableAssetFileSync(String path) {
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static String _preferredResolvedPath(RuntimeModelResolution resolution) {
    if (_isReadableAssetFileSync(resolution.privateFile.path)) {
      return resolution.privateFile.path;
    }
    if (_isReadableAssetFileSync(resolution.publicFile.path)) {
      return resolution.publicFile.path;
    }
    return resolution.file.path;
  }

  // ── inspect ───────────────────────────────────────────────────────────────

  @override
  Future<VoiceEngineStatus> inspect() async {
    logEvent(_tag, 'inspect() called — returning cached status');
    return _status;
  }

  // ── initialize ────────────────────────────────────────────────────────────

  @override
  Future<VoiceEngineStatus> initialize() async {
    if (_initialized) {
      logEvent(_tag, 'initialize() skipped — already initialised');
      return _status;
    }

    logEvent(_tag, 'initialize() start — binding ONNX libraries');

    // ── 1. Platform support guard ──────────────────────────────────────────
    final supported = !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isWindows ||
            Platform.isLinux ||
            Platform.isMacOS);
    if (!supported) {
      final msg =
          'Sherpa-ONNX voice engine is not supported on this platform.';
      logEvent(_tag, '[VOICE_UNSUPPORTED] $msg');
      _status = VoiceEngineStatus.unsupported(details: msg);
      return _status;
    }

    // ── 2. Resolve dynamic model paths (public Download -> private app) ─────
    final sttModelResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttModelFile,
      privateAbsolutePathHint: _modelPaths.sttEncoder,
    );
    final sttTokensResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttTokensFile,
      privateAbsolutePathHint: _modelPaths.sttTokens,
    );
    final ttsModelResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.ttsModelFile,
      privateAbsolutePathHint: _modelPaths.ttsModel,
    );
    final ttsLexiconResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.ttsLexiconFile,
      privateAbsolutePathHint: _modelPaths.ttsLexicon,
    );
    final ttsTokensResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.ttsTokensFile,
      privateAbsolutePathHint: _modelPaths.ttsTokens,
    );

    final String sttModelPath =
        _modelPaths.sttEncoder ?? _preferredResolvedPath(sttModelResolution);
    final String sttDecoderPath = _modelPaths.sttDecoder ?? sttModelPath;
    final String sttJoinerPath = _modelPaths.sttJoiner ?? sttModelPath;
    final String sttTokensPath =
        _modelPaths.sttTokens ?? _preferredResolvedPath(sttTokensResolution);
    final String ttsModelPath =
        _modelPaths.ttsModel ?? _preferredResolvedPath(ttsModelResolution);
    final String ttsLexiconPath =
        _modelPaths.ttsLexicon ?? _preferredResolvedPath(ttsLexiconResolution);
    final String ttsTokensPath =
        _modelPaths.ttsTokens ?? _preferredResolvedPath(ttsTokensResolution);

    logEvent(_tag, '[ASSET_CHECK_BEGIN] validating required voice files');
    final requiredModelPaths = <String, String>{
      AppConstants.sttModelFile: sttModelPath,
      AppConstants.sttTokensFile: sttTokensPath,
      AppConstants.ttsModelFile: ttsModelPath,
      AppConstants.ttsLexiconFile: ttsLexiconPath,
      AppConstants.ttsTokensFile: ttsTokensPath,
    };
    final missingModelPaths = requiredModelPaths.entries
       .where((entry) => !_isReadableAssetFileSync(entry.value))
       .map((entry) => '${entry.key}(${entry.value})')
       .toList();
    final assetsReady = missingModelPaths.isEmpty;
    if (!assetsReady) {
      final msg =
         'Risorse vocali mancanti o non valide. Scarica di nuovo i modelli vocali e riapri Live Mode.';
      logEvent(
       _tag,
       '[ASSET_CHECK_FAIL] $msg missing=${missingModelPaths.join(", ")}',
      );
      _forensicPrint(
       '[VOICE_ENGINE] [ASSET_CHECK_FAIL] $msg missing=${missingModelPaths.join(", ")}',
      );
      _status = VoiceEngineStatus(
       engineId: sherpaOnnxEngineId,
       supportedPlatform: true,
       nativeLibrariesLoaded: false,
       microphonePermissionGranted: false,
       audioSessionReady: false,
       speakerOutputReady: false,
       initialized: false,
       offlineAsrAvailable: false,
       offlineTtsAvailable: false,
       isVoiceDownloaded: false,
       details: msg,
      );
      return _status;
    }
    logEvent(_tag, '[ASSET_CHECK_COMPLETE] all required voice files are present');

    // ── 3. Bind native ONNX libraries (forensic print before native call) ──
    _forensicPrint('[VOICE_ENGINE] [ONNX_BIND_BEGIN] Calling sherpa_onnx.initBindings()');
    try {
      sherpa_onnx.initBindings();
      _forensicPrint('[VOICE_ENGINE] [ONNX_BIND_OK] Native ONNX bindings loaded');
      logEvent(_tag, '[ONNX_BIND_OK] Native ONNX bindings loaded successfully');
    } catch (e, st) {
      final msg = 'Failed to load Sherpa-ONNX native libraries: $e';
      _forensicPrint('[VOICE_ENGINE] [ONNX_BIND_FAIL] $msg\n$st');
      logEvent(_tag, '[ONNX_BIND_FAIL] $msg');
      _status = VoiceEngineStatus.unsupported(details: msg);
      return _status;
    }

    // ── 4. Build STT recognizer ────────────────────────────────────────────
    bool sttReady = false;
    logEvent(_tag, '[STT_INIT_BEGIN] Constructing OnlineRecognizer');

    _forensicPrint(
      '[VOICE_ENGINE] [STT_RECOGNIZER_ALLOC_BEGIN] '
      'encoder=$sttModelPath decoder=$sttDecoderPath joiner=$sttJoinerPath tokens=$sttTokensPath',
    );
    try {
      final modelConfig = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: sttModelPath,
          decoder: sttDecoderPath,
          joiner: sttJoinerPath,
        ),
        tokens: sttTokensPath,
        numThreads: 1,
        debug: false,
      );
      final config = sherpa_onnx.OnlineRecognizerConfig(
        model: modelConfig,
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.4,
        rule3MinUtteranceLength: 20,
      );
      _recognizer = sherpa_onnx.OnlineRecognizer(config);
      sttReady = true;
      _forensicPrint('[VOICE_ENGINE] [STT_RECOGNIZER_ALLOC_OK]');
      logEvent(_tag, '[STT_RECOGNIZER_ALLOC_OK] OnlineRecognizer ready');
    } catch (e, st) {
      final msg = 'STT recognizer init failed: $e';
      _forensicPrint('[VOICE_ENGINE] [STT_RECOGNIZER_ALLOC_FAIL] $msg\n$st');
      logEvent(_tag, '[STT_RECOGNIZER_ALLOC_FAIL] $msg');
    }

    // ── 5. Build TTS engine ────────────────────────────────────────────────
    bool ttsReady = false;
    logEvent(_tag, '[TTS_INIT_BEGIN] Constructing OfflineTts');

    _forensicPrint('[VOICE_ENGINE] [TTS_ALLOC_BEGIN] ttsModel=$ttsModelPath');
    try {
      final ttsModelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: ttsModelPath,
          lexicon: ttsLexiconPath,
          tokens: ttsTokensPath,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
      final ttsConfig = sherpa_onnx.OfflineTtsConfig(
        model: ttsModelConfig,
      );
      _tts = sherpa_onnx.OfflineTts(ttsConfig);
      ttsReady = true;
      _forensicPrint('[VOICE_ENGINE] [TTS_ALLOC_OK]');
      logEvent(_tag, '[TTS_ALLOC_OK] OfflineTts ready');
    } catch (e, st) {
      final msg = 'TTS engine init failed: $e';
      _forensicPrint('[VOICE_ENGINE] [TTS_ALLOC_FAIL] $msg\n$st');
      logEvent(_tag, '[TTS_ALLOC_FAIL] $msg');
    }

    // ── 6. Audio-channel allocation (VAD mic session check) ───────────────
    bool micReady = false;
    logEvent(_tag, '[AUDIO_SESSION_CHECK_BEGIN] Verifying AudioRecorder');
    _forensicPrint('[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_BEGIN] AudioRecorder availability');
    try {
      final hasPerm = await _recorder.hasPermission();
      micReady = hasPerm;
      _forensicPrint('[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_RESULT] hasPerm=$hasPerm');
      logEvent(_tag, '[AUDIO_SESSION_CHECK_RESULT] micReady=$micReady');
    } catch (e, st) {
      final msg = 'Audio session check failed: $e';
      _forensicPrint('[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_FAIL] $msg\n$st');
      logEvent(_tag, '[AUDIO_SESSION_CHECK_FAIL] $msg');
    }

    // ── 7. Compute final status ───────────────────────────────────────────
    final initOk = sttReady || ttsReady;
    _initialized = initOk;
    _status = VoiceEngineStatus(
      engineId: sherpaOnnxEngineId,
      supportedPlatform: true,
      nativeLibrariesLoaded: initOk,
      microphonePermissionGranted: micReady,
      audioSessionReady: micReady,
      speakerOutputReady: ttsReady,
      initialized: initOk,
      offlineAsrAvailable: sttReady,
      offlineTtsAvailable: ttsReady,
      isVoiceDownloaded: assetsReady,
      details: initOk ? null : 'STT=$sttReady TTS=$ttsReady mic=$micReady',
    );

    logEvent(
      _tag,
      '[INIT_COMPLETE] stt=$sttReady tts=$ttsReady mic=$micReady '
      'readyForInput=${_status.readyForInput} '
      'readyForOutput=${_status.readyForOutput}',
    );

    if (!initOk) {
      logEvent(
        _tag,
        '[INIT_FAIL_LOUD] initialize() completed with no functional subsystem — '
        'details: ${_status.details}',
      );
    }

    return _status;
  }

  // ── startListening ────────────────────────────────────────────────────────

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (!_status.readyForInput) {
      logEvent(_tag, '[ASR_START_BLOCKED] engine not ready for input');
      return;
    }

    if (_isListening) {
      logEvent(_tag, '[ASR_START_SKIPPED] already listening');
      return;
    }

    final recognizer = _recognizer;
    if (recognizer == null) {
      logEvent(_tag, '[ASR_START_FAIL] recognizer is null');
      return;
    }

    // Create a fresh stream handle for this utterance session.
    _asrStream?.free();
    _asrStream = recognizer.createStream();

    logEvent(_tag, '[ASR_START_BEGIN] opening mic stream locale=$localeId');
    _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_OPEN_BEGIN] sampleRate=16000 pcm16bit');

    try {
      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_OPEN_OK]');
      logEvent(_tag, '[MIC_STREAM_OPEN_OK] PCM16 stream active');

      _isListening = true;
      final activeStream = _asrStream!;

      _micSubscription = audioStream.listen(
        (Uint8List bytes) {
          if (!_isListening) return;
          final samples = _pcm16BytesToFloat32(bytes);
          activeStream.acceptWaveform(samples: samples, sampleRate: 16000);
          recognizer.decode(activeStream);

          // VAD endpoint detection.
          if (recognizer.isEndpoint(activeStream)) {
            final result = recognizer.getResult(activeStream);
            final text = result.text.trim();
            logEvent(
              _tag,
              '[VAD_ENDPOINT] isEndpoint=true text="${text.isEmpty ? "<empty>" : text}"',
            );
            if (text.isNotEmpty) {
              onResult(text, true);
            }
            recognizer.reset(activeStream);
          } else {
            // Emit partial result for live-subtitle rendering.
            final partial = recognizer.getResult(activeStream);
            final partialText = partial.text.trim();
            if (partialText.isNotEmpty) {
              onResult(partialText, false);
            }
          }
        },
        onError: (Object error, StackTrace st) {
          final msg = 'Mic stream error: $error';
          _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_ERROR] $msg\n$st');
          logEvent(_tag, '[MIC_STREAM_ERROR] $msg');
          _isListening = false;
        },
        onDone: () {
          logEvent(_tag, '[MIC_STREAM_DONE] mic stream closed');
          _isListening = false;
        },
        cancelOnError: false,
      );
    } catch (e, st) {
      final msg = 'Failed to open mic stream: $e';
      _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_OPEN_FAIL] $msg\n$st');
      logEvent(_tag, '[MIC_STREAM_OPEN_FAIL] $msg');
      _isListening = false;
    }
  }

  // ── stopListening ─────────────────────────────────────────────────────────

  @override
  Future<void> stopListening() async {
    logEvent(_tag, '[ASR_STOP_BEGIN]');
    _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_CLOSE_BEGIN]');

    _isListening = false;
    await _micSubscription?.cancel();
    _micSubscription = null;

    try {
      await _recorder.stop();
    } catch (e) {
      logEvent(_tag, '[MIC_STREAM_STOP_WARN] recorder.stop() error: $e');
    }

    _forensicPrint('[VOICE_ENGINE] [MIC_STREAM_CLOSE_OK]');
    logEvent(_tag, '[ASR_STOP_DONE]');
  }

  // ── speak ─────────────────────────────────────────────────────────────────

  @override
  Future<void> speak(String text) async {
    final sanitized = text.trim();
    if (sanitized.isEmpty) return;

    if (!_status.readyForOutput) {
      logEvent(_tag, '[TTS_BLOCKED] engine not ready for output text="$sanitized"');
      return;
    }

    final tts = _tts;
    if (tts == null) {
      logEvent(_tag, '[TTS_NULL] tts engine is null, cannot speak');
      return;
    }

    logEvent(_tag, '[TTS_GENERATE_BEGIN] text="${sanitized.length > 60 ? sanitized.substring(0, 60) : sanitized}..."');

    try {
      final audio = tts.generate(
        text: sanitized,
        sid: 0,
        speed: _status.speechRate,
      );
      _pendingTtsSamples = audio.samples;
      _pendingTtsSampleRate = audio.sampleRate;

      logEvent(
        _tag,
        '[TTS_GENERATE_OK] samples=${audio.samples.length} sampleRate=${audio.sampleRate}',
      );

      // Phase 2: pipe generated samples to the hardware speaker via
      // AudioStreamPlayer.  The push is fire-and-forget; the player
      // serialises concurrent chunks and clears itself on stopSpeaking().
      _audioPlayer.push(audio.samples, audio.sampleRate);

      logEvent(_tag, '[TTS_PLAYBACK_ENQUEUED] queued ${audio.samples.length} samples at ${audio.sampleRate} Hz');
    } catch (e, st) {
      final msg = 'TTS generation error: $e';
      _forensicPrint('[VOICE_ENGINE] [TTS_GENERATE_FAIL] $msg\n$st');
      logEvent(_tag, '[TTS_GENERATE_FAIL] $msg');
    }
  }

  // ── stopSpeaking ──────────────────────────────────────────────────────────

  @override
  Future<void> stopSpeaking() async {
    logEvent(_tag, '[TTS_STOP]');
    // Stop the audio player immediately (clears queue + flushes hardware
    // ring-buffer) for low-latency barge-in response.
    _audioPlayer.stop();
    _pendingTtsSamples = null;
  }

  // ── dispose ───────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    logEvent(_tag, '[DISPOSE_BEGIN]');
    _forensicPrint('[VOICE_ENGINE] [DISPOSE_BEGIN] releasing all native handles');

    await stopListening();
    await stopSpeaking();

    // Free native ONNX handles in safe order.
    try {
      _asrStream?.free();
      _asrStream = null;
      logEvent(_tag, '[DISPOSE_ASR_STREAM_FREE_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_ASR_STREAM_FREE_FAIL] $e');
    }

    try {
      _recognizer?.free();
      _recognizer = null;
      logEvent(_tag, '[DISPOSE_RECOGNIZER_FREE_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_RECOGNIZER_FREE_FAIL] $e');
    }

    try {
      _tts?.free();
      _tts = null;
      logEvent(_tag, '[DISPOSE_TTS_FREE_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_TTS_FREE_FAIL] $e');
    }

    try {
      await _recorder.dispose();
      logEvent(_tag, '[DISPOSE_RECORDER_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_RECORDER_FAIL] $e');
    }

    // Dispose the audio output player after the recorder so any in-progress
    // TTS playback is cleanly terminated.
    try {
      _audioPlayer.dispose();
      logEvent(_tag, '[DISPOSE_AUDIO_PLAYER_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_AUDIO_PLAYER_FAIL] $e');
    }

    _initialized = false;
    _status = VoiceEngineStatus.unsupported(
      details: 'Engine disposed.',
    );
    _forensicPrint('[VOICE_ENGINE] [DISPOSE_DONE] all handles released');
    logEvent(_tag, '[DISPOSE_DONE]');
  }

  // ── PCM conversion ────────────────────────────────────────────────────────

  /// Converts raw PCM-16 little-endian bytes from the microphone stream into
  /// normalised [Float32List] samples in the range [-1.0, 1.0].
  ///
  /// Sherpa-ONNX [OnlineStream.acceptWaveform] requires Float32 samples; the
  /// standard normalisation factor is 1 / 32768.0 for signed 16-bit values.
  static Float32List _pcm16BytesToFloat32(Uint8List bytes) {
    final numSamples = bytes.length ~/ 2;
    final samples = Float32List(numSamples);
    final byteData = ByteData.sublistView(bytes);
    for (int i = 0; i < numSamples; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}
