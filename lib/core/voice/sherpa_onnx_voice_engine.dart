import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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
/// Differenze rispetto alla versione precedente:
/// - TTS usa `data_dir` (espeak-ng-data) invece di `lexicon` per i modelli Piper.
/// - Il path della cartella espeak-ng-data viene risolto da [VoiceModelPaths.ttsDataDir]
///   oppure calcolato automaticamente come sottocartella di [AppConstants.ttsEspeakDataDir]
///   nella directory privata dei modelli.
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

  final AudioStreamPlayer _audioPlayer = AudioStreamPlayer();

  Float32List? _pendingTtsSamples;
  int _pendingTtsSampleRate = 22050;

  @override
  bool get isListening => _isListening;

  @override
  bool get isSpeaking => _audioPlayer.isPlaying;

  Float32List? get pendingTtsSamples => _pendingTtsSamples;
  int get pendingTtsSampleRate => _pendingTtsSampleRate;

  static void _forensicPrint(String message) {
    stdout.writeln(message);
  }

  static bool _isReadableAssetFileSync(String path) {
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isReadableDirectorySync(String path) {
    try {
      return Directory(path).existsSync();
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

  @override
  Future<VoiceEngineStatus> inspect() async {
    logEvent(_tag, 'inspect() called — returning cached status');
    return _status;
  }

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
      const msg =
          'Sherpa-ONNX voice engine is not supported on this platform.';
      logEvent(_tag, '[VOICE_UNSUPPORTED] $msg');
      _status = VoiceEngineStatus.unsupported(details: msg);
      return _status;
    }

    // ── 2. Resolve STT model paths ─────────────────────────────────────────
    final sttEncoderResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttEncoderFile,
      privateAbsolutePathHint: _modelPaths.sttEncoder,
    );
    final sttDecoderResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttDecoderFile,
      privateAbsolutePathHint: _modelPaths.sttDecoder,
    );
    final sttJoinerResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttJoinerFile,
      privateAbsolutePathHint: _modelPaths.sttJoiner,
    );
    final sttTokensResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.sttTokensFile,
      privateAbsolutePathHint: _modelPaths.sttTokens,
    );

    final String sttEncoderPath =
        _modelPaths.sttEncoder ?? _preferredResolvedPath(sttEncoderResolution);
    final String sttDecoderPath =
        _modelPaths.sttDecoder ?? _preferredResolvedPath(sttDecoderResolution);
    final String sttJoinerPath =
        _modelPaths.sttJoiner ?? _preferredResolvedPath(sttJoinerResolution);
    final String sttTokensPath =
        _modelPaths.sttTokens ?? _preferredResolvedPath(sttTokensResolution);

    // ── 3. Resolve TTS model paths (Piper: usa data_dir, non lexicon) ──────
    final ttsModelResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.ttsModelFile,
      privateAbsolutePathHint: _modelPaths.ttsModel,
    );
    final ttsTokensResolution = await _pathResolver.resolveForRead(
      fileName: AppConstants.ttsTokensFile,
      privateAbsolutePathHint: _modelPaths.ttsTokens,
    );

    final String ttsModelPath =
        _modelPaths.ttsModel ?? _preferredResolvedPath(ttsModelResolution);
    final String ttsTokensPath =
        _modelPaths.ttsTokens ?? _preferredResolvedPath(ttsTokensResolution);

    // Risolvi espeak-ng-data: prima da VoiceModelPaths.ttsDataDir,
    // poi calcolato come sottocartella nella directory privata dei modelli.
    final privateDir = await _pathResolver.privateModelsDirectory();
    final String ttsDataDir = (_modelPaths.ttsDataDir?.isNotEmpty ?? false)
        ? _modelPaths.ttsDataDir!
        : p.join(privateDir.path, AppConstants.ttsEspeakDataDir);

    logEvent(_tag, '[ASSET_CHECK_BEGIN] validating required voice files');

    // Valida file STT.
    final requiredSttPaths = <String, String>{
      AppConstants.sttEncoderFile: sttEncoderPath,
      AppConstants.sttDecoderFile: sttDecoderPath,
      AppConstants.sttJoinerFile: sttJoinerPath,
      AppConstants.sttTokensFile: sttTokensPath,
    };
    final missingStt = requiredSttPaths.entries
        .where((e) => !_isReadableAssetFileSync(e.value))
        .map((e) => '${e.key}(${e.value})')
        .toList();

    // Valida file TTS.
    final missingTts = <String>[];
    if (!_isReadableAssetFileSync(ttsModelPath)) {
      missingTts.add('${AppConstants.ttsModelFile}($ttsModelPath)');
    }
    if (!_isReadableAssetFileSync(ttsTokensPath)) {
      missingTts.add('${AppConstants.ttsTokensFile}($ttsTokensPath)');
    }
    if (!_isReadableDirectorySync(ttsDataDir)) {
      missingTts.add('${AppConstants.ttsEspeakDataDir}($ttsDataDir)');
    }

    final allMissing = [...missingStt, ...missingTts];
    final assetsReady = allMissing.isEmpty;

    if (!assetsReady) {
      const msg =
          'Risorse vocali mancanti o non valide. Scarica di nuovo i modelli vocali e riapri Live Mode.';
      logEvent(
        _tag,
        '[ASSET_CHECK_FAIL] $msg missing=${allMissing.join(", ")}',
      );
      _forensicPrint(
        '[VOICE_ENGINE] [ASSET_CHECK_FAIL] $msg missing=${allMissing.join(", ")}',
      );
      _status = const VoiceEngineStatus(
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
        details:
            'Risorse vocali mancanti o non valide. Scarica di nuovo i modelli vocali e riapri Live Mode.',
      );
      return _status;
    }
    logEvent(
        _tag, '[ASSET_CHECK_COMPLETE] all required voice files are present');

    // ── 4. Bind native ONNX libraries ──────────────────────────────────────
    _forensicPrint(
        '[VOICE_ENGINE] [ONNX_BIND_BEGIN] Calling sherpa_onnx.initBindings()');
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

    // ── 5. Build STT recognizer ────────────────────────────────────────────
    bool sttReady = false;
    logEvent(_tag, '[STT_INIT_BEGIN] Constructing OnlineRecognizer');
    _forensicPrint(
      '[VOICE_ENGINE] [STT_RECOGNIZER_ALLOC_BEGIN] '
      'encoder=$sttEncoderPath decoder=$sttDecoderPath '
      'joiner=$sttJoinerPath tokens=$sttTokensPath',
    );
    try {
      final modelConfig = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: sttEncoderPath,
          decoder: sttDecoderPath,
          joiner: sttJoinerPath,
        ),
        tokens: sttTokensPath,
        numThreads: AppConstants.sttNumThreads,
        provider: 'cpu',
        debug: false,
        modelType: AppConstants.sttModelType,
      );
      final config = sherpa_onnx.OnlineRecognizerConfig(
        model: modelConfig,
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.4,
        rule3MinUtteranceLength: 20.0,
      );
      _forensicPrint(
        '[VOICE_ENGINE] [STT_CONFIG_SHAPE] '
        'modelType=${AppConstants.sttModelType} '
        'provider=cpu numThreads=${AppConstants.sttNumThreads} '
        'rule1=2.4 rule2=1.4 rule3=20.0',
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

    // ── 6. Build TTS engine (Piper: data_dir, no lexicon) ─────────────────
    bool ttsReady = false;
    logEvent(_tag, '[TTS_INIT_BEGIN] Constructing OfflineTts (Piper)');
    _forensicPrint(
      '[VOICE_ENGINE] [TTS_ALLOC_BEGIN] '
      'model=$ttsModelPath tokens=$ttsTokensPath dataDir=$ttsDataDir',
    );
    try {
      final ttsModelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: ttsModelPath,
          lexicon: '',       // Piper non usa lexicon.txt
          tokens: ttsTokensPath,
          dataDir: ttsDataDir, // espeak-ng-data per Piper
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
      logEvent(_tag, '[TTS_ALLOC_OK] OfflineTts (Piper) ready');
    } catch (e, st) {
      final msg = 'TTS engine init failed: $e';
      _forensicPrint('[VOICE_ENGINE] [TTS_ALLOC_FAIL] $msg\n$st');
      logEvent(_tag, '[TTS_ALLOC_FAIL] $msg');
    }

    // ── 7. Audio-channel allocation ────────────────────────────────────────
    bool micReady = false;
    logEvent(_tag, '[AUDIO_SESSION_CHECK_BEGIN] Verifying AudioRecorder');
    _forensicPrint(
        '[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_BEGIN] AudioRecorder availability');
    try {
      final hasPerm = await _recorder.hasPermission();
      micReady = hasPerm;
      _forensicPrint(
          '[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_RESULT] hasPerm=$hasPerm');
      logEvent(_tag, '[AUDIO_SESSION_CHECK_RESULT] micReady=$micReady');
    } catch (e, st) {
      final msg = 'Audio session check failed: $e';
      _forensicPrint('[VOICE_ENGINE] [MIC_CHANNEL_ALLOC_FAIL] $msg\n$st');
      logEvent(_tag, '[AUDIO_SESSION_CHECK_FAIL] $msg');
    }

    // ── 8. Compute final status ────────────────────────────────────────────
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

    _asrStream?.free();
    _asrStream = recognizer.createStream();

    logEvent(_tag, '[ASR_START_BEGIN] opening mic stream locale=$localeId');
    _forensicPrint(
        '[VOICE_ENGINE] [MIC_STREAM_OPEN_BEGIN] sampleRate=16000 pcm16bit');

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
      logEvent(
          _tag, '[TTS_BLOCKED] engine not ready for output text="$sanitized"');
      return;
    }

    final tts = _tts;
    if (tts == null) {
      logEvent(_tag, '[TTS_NULL] tts engine is null, cannot speak');
      return;
    }

    logEvent(
      _tag,
      '[TTS_GENERATE_BEGIN] text="${sanitized.length > 60 ? sanitized.substring(0, 60) : sanitized}..."',
    );

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

      _audioPlayer.push(audio.samples, audio.sampleRate);
      logEvent(
        _tag,
        '[TTS_PLAYBACK_ENQUEUED] queued ${audio.samples.length} samples at ${audio.sampleRate} Hz',
      );
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
    _audioPlayer.stop();
    _pendingTtsSamples = null;
  }

  // ── dispose ───────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    logEvent(_tag, '[DISPOSE_BEGIN]');
    _forensicPrint(
        '[VOICE_ENGINE] [DISPOSE_BEGIN] releasing all native handles');

    await stopListening();
    await stopSpeaking();

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

    try {
      _audioPlayer.dispose();
      logEvent(_tag, '[DISPOSE_AUDIO_PLAYER_OK]');
    } catch (e) {
      logEvent(_tag, '[DISPOSE_AUDIO_PLAYER_FAIL] $e');
    }

    _initialized = false;
    _status = VoiceEngineStatus.unsupported(details: 'Engine disposed.');
    _forensicPrint('[VOICE_ENGINE] [DISPOSE_DONE] all handles released');
    logEvent(_tag, '[DISPOSE_DONE]');
  }

  // ── PCM conversion ────────────────────────────────────────────────────────

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
