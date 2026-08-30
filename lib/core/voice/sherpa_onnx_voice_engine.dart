import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';
import 'package:ai_orchestrator/core/voice/audio_stream_player.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';

class SherpaOnnxVoiceEngine with RuntimeEventEmitter implements VoiceEngine {
  SherpaOnnxVoiceEngine({
    VoiceModelPaths? modelPaths,
  }) : _modelPaths = modelPaths ?? const VoiceModelPaths();

  static const String _tag = 'VOICE_ENGINE';

  static const int _sampleRate = 16000;
  static const int _channels = 1;

  /*
   * These are deliberately conservative minimum sizes for the
   * Zipformer assets used by this project.
   *
   * A non-empty ONNX file is NOT sufficient validation.
   * A truncated ONNX file can exist on disk and still cause the
   * native Sherpa/ONNX runtime to abort when it is instantiated.
   */
  static const int _minSttEncoderBytes = 50 * 1024 * 1024;
  static const int _minSttDecoderBytes = 512 * 1024;
  static const int _minSttJoinerBytes = 100 * 1024;
  static const int _minSttTokensBytes = 1024;

  final VoiceModelPaths _modelPaths;

  final RuntimeModelPathResolver _pathResolver =
      const RuntimeModelPathResolver();

  final AudioRecorder _recorder = AudioRecorder();
  final AudioStreamPlayer _audioPlayer = AudioStreamPlayer();

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _asrStream;
  sherpa_onnx.OfflineTts? _tts;

  StreamSubscription<Uint8List>? _micSubscription;

  VoiceEngineStatus _status = VoiceEngineStatus.unsupported();

  bool _isListening = false;
  bool _initialized = false;
  bool _initializing = false;
  bool _disposed = false;

  /*
   * Tracks the binding lifecycle for this VoiceEngine instance.
   *
   * sherpa-onnx keeps FFI binding state per isolate. STT and TTS must
   * therefore be created only after the bindings have been initialized
   * in the isolate that is executing this engine.
   */
  Future<bool>? _bindingsInitFuture;
  bool _bindingsReady = false;

  /*
   * TTS initialization is lazy.
   *
   * Live must not initialize Piper/espeak together with the microphone.
   * This future prevents two simultaneous speak() calls from creating
   * two native TTS instances.
   */
  Future<bool>? _ttsInitFuture;

  /*
   * TTS generation is serialized independently from TTS initialization.
   *
   * OfflineTts.generate() is a synchronous native operation. The Dart
   * Future queue guarantees that two speak() calls cannot concurrently
   * invoke generate() on the same native OfflineTts instance.
   *
   * The generation number is also used to invalidate queued/in-flight
   * requests after stopSpeaking() or dispose().
   */
  Future<void> _ttsGenerationTail = Future<void>.value();
  int _ttsGeneration = 0;

  Float32List? _pendingTtsSamples;
  int _pendingTtsSampleRate = 22050;

  @override
  bool get isListening => _isListening;

  @override
  bool get isSpeaking => _audioPlayer.isPlaying;

  Float32List? get pendingTtsSamples => _pendingTtsSamples;

  int get pendingTtsSampleRate => _pendingTtsSampleRate;

  static bool _isReadableAssetFileSync(String path) {
    try {
      final file = File(path);

      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isValidSttAssetSync(
    String path,
    int minimumBytes,
  ) {
    try {
      final file = File(path);

      if (!file.existsSync()) {
        return false;
      }

      final length = file.lengthSync();

      return length >= minimumBytes;
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

  static String _preferredResolvedPath(
    RuntimeModelResolution resolution,
  ) {
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
    if (_disposed) {
      return VoiceEngineStatus.unsupported(
        details: 'Voice engine has been disposed.',
      );
    }

    // Intentionally cached: inspect() must remain cheap and side-effect free.
    return _status;
  }

  /*
   * Ensure sherpa-onnx native bindings are initialized exactly once
   * for this engine instance.
   *
   * The Future gate is important because initialize() and a lazy TTS
   * request can otherwise race and both enter initBindings().
   *
   * We deliberately use the synchronous API because all callers are
   * already executing on the same Dart isolate and the native binding
   * initialization itself is synchronous.
   */
  Future<bool> _ensureNativeBindings() async {
    if (_disposed) {
      return false;
    }

    if (_bindingsReady) {
      return true;
    }

    final inFlight = _bindingsInitFuture;

    if (inFlight != null) {
      return inFlight;
    }

    final future = _initializeNativeBindings();

    _bindingsInitFuture = future;

    try {
      final ready = await future;

      if (_disposed) {
        return false;
      }

      _bindingsReady = ready;

      return ready;
    } finally {
      if (identical(_bindingsInitFuture, future)) {
        _bindingsInitFuture = null;
      }
    }
  }

  Future<bool> _initializeNativeBindings() async {
    if (_disposed) {
      return false;
    }

    final supported = !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isWindows ||
            Platform.isLinux ||
            Platform.isMacOS);

    if (!supported) {
      const message =
          'Sherpa-ONNX voice engine is not supported on this platform.';

      logEvent(_tag, '[VOICE_UNSUPPORTED] $message');

      _status = VoiceEngineStatus.unsupported(
        details: message,
      );

      return false;
    }

    try {
      /*
       * This is the single native binding initialization point for
       * this VoiceEngine instance.
       *
       * Both STT and lazy TTS pass through _ensureNativeBindings().
       */
      sherpa_onnx.initBindings();

      logEvent(_tag, '[ONNX_BIND_OK]');

      return true;
    } catch (error) {
      final message =
          'Failed to load Sherpa-ONNX native libraries: $error';

      logEvent(_tag, '[ONNX_BIND_FAIL] $message');

      _status = VoiceEngineStatus.unsupported(
        details: message,
      );

      return false;
    }
  }

  Future<bool> _initializeStt() async {
    if (_disposed) {
      return false;
    }

    try {
      final bindingsReady = await _ensureNativeBindings();

      if (!bindingsReady || _disposed) {
        logEvent(
          _tag,
          '[STT_BLOCKED] native bindings unavailable',
        );

        return false;
      }

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

      final sttEncoderPath = _modelPaths.sttEncoder ??
          _preferredResolvedPath(sttEncoderResolution);

      final sttDecoderPath = _modelPaths.sttDecoder ??
          _preferredResolvedPath(sttDecoderResolution);

      final sttJoinerPath = _modelPaths.sttJoiner ??
          _preferredResolvedPath(sttJoinerResolution);

      final sttTokensPath = _modelPaths.sttTokens ??
          _preferredResolvedPath(sttTokensResolution);

      final invalid = <String>[];

      if (!_isValidSttAssetSync(
        sttEncoderPath,
        _minSttEncoderBytes,
      )) {
        invalid.add(
          '${AppConstants.sttEncoderFile}'
          '($sttEncoderPath, min=$_minSttEncoderBytes)',
        );
      }

      if (!_isValidSttAssetSync(
        sttDecoderPath,
        _minSttDecoderBytes,
      )) {
        invalid.add(
          '${AppConstants.sttDecoderFile}'
          '($sttDecoderPath, min=$_minSttDecoderBytes)',
        );
      }

      if (!_isValidSttAssetSync(
        sttJoinerPath,
        _minSttJoinerBytes,
      )) {
        invalid.add(
          '${AppConstants.sttJoinerFile}'
          '($sttJoinerPath, min=$_minSttJoinerBytes)',
        );
      }

      if (!_isValidSttAssetSync(
        sttTokensPath,
        _minSttTokensBytes,
      )) {
        invalid.add(
          '${AppConstants.sttTokensFile}'
          '($sttTokensPath, min=$_minSttTokensBytes)',
        );
      }

      if (invalid.isNotEmpty) {
        logEvent(
          _tag,
          '[STT_ASSETS_INVALID] ${invalid.join(", ")}',
        );

        return false;
      }

      logEvent(
        _tag,
        '[STT_ASSETS_VALIDATED] '
        'encoder=${File(sttEncoderPath).lengthSync()} '
        'decoder=${File(sttDecoderPath).lengthSync()} '
        'joiner=${File(sttJoinerPath).lengthSync()} '
        'tokens=${File(sttTokensPath).lengthSync()}',
      );

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

      final recognizerConfig = sherpa_onnx.OnlineRecognizerConfig(
        model: modelConfig,
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.4,
        rule3MinUtteranceLength: 20.0,
      );

      logEvent(
        _tag,
        '[STT_BEFORE_RECOGNIZER_CREATE] '
        'modelType=${AppConstants.sttModelType} '
        'provider=cpu',
      );

      final recognizer = sherpa_onnx.OnlineRecognizer(
        recognizerConfig,
      );

      if (_disposed) {
        try {
          recognizer.free();
        } catch (_) {}

        return false;
      }

      _recognizer = recognizer;

      logEvent(
        _tag,
        '[STT_READY] OnlineRecognizer ready',
      );

      return true;
    } catch (error) {
      final message = 'STT recognizer init failed: $error';

      logEvent(
        _tag,
        '[STT_INIT_FAIL] $message',
      );

      _recognizer = null;

      return false;
    }
  }

  Future<bool> _initializeTts() async {
    if (_disposed) {
      return false;
    }

    try {
      /*
       * IMPORTANT:
       *
       * TTS is lazy, but it still requires the sherpa-onnx FFI
       * bindings to be initialized in the current isolate.
       *
       * Do this immediately before resolving/creating OfflineTts.
       */
      final bindingsReady = await _ensureNativeBindings();

      if (!bindingsReady || _disposed) {
        logEvent(
          _tag,
          '[TTS_INIT_FAIL] Native bindings unavailable',
        );

        return false;
      }

      logEvent(
        _tag,
        '[TTS_BINDINGS_READY]',
      );

      final ttsModelResolution = await _pathResolver.resolveForRead(
        fileName: AppConstants.ttsModelFile,
        privateAbsolutePathHint: _modelPaths.ttsModel,
      );

      final ttsTokensResolution = await _pathResolver.resolveForRead(
        fileName: AppConstants.ttsTokensFile,
        privateAbsolutePathHint: _modelPaths.ttsTokens,
      );

      final ttsModelPath = _modelPaths.ttsModel ??
          _preferredResolvedPath(ttsModelResolution);

      final ttsTokensPath = _modelPaths.ttsTokens ??
          _preferredResolvedPath(ttsTokensResolution);

      final privateDir =
          await _pathResolver.privateModelsDirectory();

      final ttsDataDir =
          (_modelPaths.ttsDataDir?.isNotEmpty ?? false)
              ? _modelPaths.ttsDataDir!
              : p.join(
                  privateDir.path,
                  AppConstants.ttsEspeakDataDir,
                );

      final missing = <String>[];

      if (!_isReadableAssetFileSync(ttsModelPath)) {
        missing.add(
          '${AppConstants.ttsModelFile}($ttsModelPath)',
        );
      }

      if (!_isReadableAssetFileSync(ttsTokensPath)) {
        missing.add(
          '${AppConstants.ttsTokensFile}($ttsTokensPath)',
        );
      }

      if (!_isReadableDirectorySync(ttsDataDir)) {
        missing.add(
          '${AppConstants.ttsEspeakDataDir}($ttsDataDir)',
        );
      }

      if (missing.isNotEmpty) {
        logEvent(
          _tag,
          '[TTS_INIT_FAIL] Missing TTS assets: ${missing.join(", ")}',
        );

        return false;
      }

      final ttsModelConfig =
          sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: ttsModelPath,
          lexicon: '',
          tokens: ttsTokensPath,
          dataDir: ttsDataDir,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );

      final ttsConfig = sherpa_onnx.OfflineTtsConfig(
        model: ttsModelConfig,
      );

      logEvent(
        _tag,
        '[TTS_BEFORE_INIT] lazy=true',
      );

      final tts = sherpa_onnx.OfflineTts(ttsConfig);

      if (_disposed) {
        try {
          tts.free();
        } catch (_) {}

        return false;
      }

      _tts = tts;

      logEvent(
        _tag,
        '[TTS_READY] OfflineTts ready',
      );

      return true;
    } catch (error) {
      final message = 'TTS engine init failed: $error';

      logEvent(
        _tag,
        '[TTS_INIT_FAIL] $message',
      );

      _tts = null;

      return false;
    }
  }

  Future<bool> _ensureTtsInitialized() async {
    if (_disposed) {
      return false;
    }

    if (_tts != null) {
      return true;
    }

    final inFlight = _ttsInitFuture;

    if (inFlight != null) {
      return inFlight;
    }

    logEvent(
      _tag,
      '[TTS_LAZY_INIT]',
    );

    final future = _initializeTts();

    _ttsInitFuture = future;

    try {
      final ready = await future;

      if (_disposed) {
        return false;
      }

      if (ready) {
        _status = _status.copyWith(
          speakerOutputReady: true,
          offlineTtsAvailable: true,
        );

        logEvent(
          _tag,
          '[TTS_LAZY_READY]',
        );
      } else {
        logEvent(
          _tag,
          '[TTS_LAZY_FAIL]',
        );
      }

      return ready;
    } finally {
      if (identical(_ttsInitFuture, future)) {
        _ttsInitFuture = null;
      }
    }
  }

  Future<bool> _initializeMic() async {
    if (_disposed) {
      return false;
    }

    try {
      final hasPermission = await _recorder.hasPermission();

      if (_disposed) {
        return false;
      }

      logEvent(
        _tag,
        '[MIC_STATUS] permission=$hasPermission',
      );

      return hasPermission;
    } catch (error) {
      logEvent(
        _tag,
        '[MIC_STATUS_FAIL] $error',
      );

      return false;
    }
  }

  @override
  Future<VoiceEngineStatus> initialize() async {
    if (_disposed) {
      return VoiceEngineStatus.unsupported(
        details: 'Voice engine has been disposed.',
      );
    }

    if (_initialized) {
      return _status;
    }

    if (_initializing) {
      return _status;
    }

    _initializing = true;

    try {
      final nativeReady = await _ensureNativeBindings();

      if (!nativeReady || _disposed) {
        return _status;
      }

      /*
       * CRITICAL LIVE ORDER:
       *
       * 1. native bindings
       * 2. STT
       * 3. microphone
       *
       * TTS/Piper/espeak is intentionally NOT initialized here.
       */
      final sttReady = await _initializeStt();

      if (_disposed) {
        return _status;
      }

      final micReady = await _initializeMic();

      if (_disposed) {
        return _status;
      }

      final initOk = sttReady;

      _initialized = initOk;

      _status = VoiceEngineStatus(
        engineId: sherpaOnnxEngineId,
        supportedPlatform: true,
        nativeLibrariesLoaded: true,
        microphonePermissionGranted: micReady,
        audioSessionReady: micReady,
        speakerOutputReady: false,
        initialized: initOk,
        offlineAsrAvailable: sttReady,
        offlineTtsAvailable: false,
        isVoiceDownloaded: sttReady,
        details: initOk
            ? null
            : 'Risorse vocali STT non disponibili.',
      );

      logEvent(
        _tag,
        '[INIT_COMPLETE] '
        'stt=$sttReady '
        'tts=false '
        'mic=$micReady '
        'ttsDeferred=true',
      );

      return _status;
    } catch (error) {
      logEvent(
        _tag,
        '[INIT_FAIL] Voice initialization failed: $error',
      );

      _initialized = false;

      _status = VoiceEngineStatus.unsupported(
        details: 'Voice initialization failed.',
      );

      return _status;
    } finally {
      _initializing = false;
    }
  }

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (_disposed) {
      return;
    }

    if (_isListening) {
      return;
    }

    final recognizer = _recognizer;

    if (recognizer == null) {
      logEvent(
        _tag,
        '[ASR_BLOCKED] recognizer unavailable',
      );

      return;
    }

    try {
      await _closeMicSafely();
      await _closeAsrStreamSafely();

      if (_disposed) {
        return;
      }

      final hasPermission = await _recorder.hasPermission();

      if (!hasPermission || _disposed) {
        logEvent(
          _tag,
          '[ASR_BLOCKED] microphone unavailable',
        );

        return;
      }

      final activeStream = recognizer.createStream();

      if (_disposed) {
        try {
          activeStream.free();
        } catch (_) {}

        return;
      }

      _asrStream = activeStream;

      logEvent(
        _tag,
        '[ASR_BEFORE_START_STREAM]',
      );

      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: _channels,
        ),
      );

      if (_disposed) {
        try {
          await _recorder.stop();
        } catch (_) {}

        await _closeAsrStreamSafely();

        return;
      }

      _isListening = true;

      logEvent(
        _tag,
        '[ASR_STARTED] sampleRate=$_sampleRate',
      );

      _micSubscription = audioStream.listen(
        (Uint8List bytes) {
          if (_disposed || !_isListening) {
            return;
          }

          try {
            if (bytes.length < 2) {
              return;
            }

            final stream = _asrStream;

            if (stream == null) {
              return;
            }

            final samples = _pcm16BytesToFloat32(bytes);

            if (samples.isEmpty) {
              return;
            }

            stream.acceptWaveform(
              samples: samples,
              sampleRate: _sampleRate,
            );

            while (recognizer.isReady(stream)) {
              logEvent(
                _tag,
                '[ASR_BEFORE_DECODE]',
              );

              recognizer.decode(stream);
            }

            if (recognizer.isEndpoint(stream)) {
              final result = recognizer.getResult(stream);
              final text = result.text.trim();

              if (text.isNotEmpty) {
                onResult(text, true);
              }

              recognizer.reset(stream);
            } else {
              final result = recognizer.getResult(stream);
              final partialText = result.text.trim();

              if (partialText.isNotEmpty) {
                onResult(partialText, false);
              }
            }
          } catch (error) {
            logEvent(
              _tag,
              '[ASR_FRAME_FAIL] $error',
            );
          }
        },
        onError: (Object error) {
          if (_disposed) {
            return;
          }

          logEvent(
            _tag,
            '[MIC_STREAM_ERROR] $error',
          );

          _isListening = false;
        },
        onDone: () {
          if (_disposed) {
            return;
          }

          _isListening = false;

          logEvent(
            _tag,
            '[MIC_STREAM_DONE]',
          );
        },
        cancelOnError: false,
      );
    } catch (error) {
      logEvent(
        _tag,
        '[ASR_START_FAIL] $error',
      );

      _isListening = false;

      await _closeMicSafely();
      await _closeAsrStreamSafely();
    }
  }

  @override
  Future<void> stopListening() async {
    if (_disposed && !_isListening) {
      return;
    }

    _isListening = false;

    await _closeMicSafely();
    await _closeAsrStreamSafely();
  }

  Future<void> _closeMicSafely() async {
    final subscription = _micSubscription;
    _micSubscription = null;

    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (error) {
        logEvent(
          _tag,
          '[MIC_CANCEL_WARN] $error',
        );
      }
    }

    try {
      await _recorder.stop();
    } catch (error) {
      logEvent(
        _tag,
        '[MIC_STOP_WARN] $error',
      );
    }
  }

  Future<void> _closeAsrStreamSafely() async {
    final stream = _asrStream;
    _asrStream = null;

    if (stream == null) {
      return;
    }

    try {
      stream.free();
    } catch (error) {
      logEvent(
        _tag,
        '[ASR_STREAM_FREE_WARN] $error',
      );
    }
  }

  /*
   * Enqueues one TTS generation request.
   *
   * Important:
   * OfflineTts.generate() itself is synchronous, so the Future queue does
   * not make generation non-blocking. Its purpose here is serialization:
   * only one native generate() call may execute at a time.
   *
   * The lifecycle generation prevents stale queued requests from reaching
   * the audio player after stopSpeaking() or dispose().
   */
  Future<void> _enqueueTtsGeneration(
    String text, {
    required int generation,
  }) async {
    final previous = _ttsGenerationTail;

    final future = Future<void>(() async {
      await previous;

      if (_disposed ||
          generation != _ttsGeneration) {
        logEvent(
          _tag,
          '[TTS_SKIPPED] '
          'reason=lifecycle_invalidated '
          'generation=$generation '
          'currentGeneration=$_ttsGeneration '
          'disposed=$_disposed',
        );
        return;
      }

      final tts = _tts;

      if (tts == null) {
        logEvent(
          _tag,
          '[TTS_SKIPPED] reason=engine_unavailable',
        );
        return;
      }

      try {
        logEvent(
          _tag,
          '[TTS_GENERATE_BEGIN] '
          'generation=$generation '
          'chars=${text.length}',
        );

        /*
         * This call is intentionally synchronous because that is the
         * OfflineTts API exposed by sherpa-onnx.
         */
        final audio = tts.generate(
          text: text,
          sid: 0,
          speed: _status.speechRate,
        );

        if (_disposed ||
            generation != _ttsGeneration) {
          logEvent(
            _tag,
            '[TTS_GENERATE_DISCARDED] '
            'generation=$generation '
            'currentGeneration=$_ttsGeneration '
            'disposed=$_disposed',
          );
          return;
        }

        _pendingTtsSamples = audio.samples;
        _pendingTtsSampleRate = audio.sampleRate;

        _audioPlayer.push(
          audio.samples,
          audio.sampleRate,
        );

        logEvent(
          _tag,
          '[TTS_AUDIO_READY] '
          'samples=${audio.samples.length} '
          'sampleRate=${audio.sampleRate} '
          'generation=$generation',
        );
      } catch (error) {
        logEvent(
          _tag,
          '[TTS_FAIL] '
          'generation=$generation '
          'error=$error',
        );
      }
    });

    _ttsGenerationTail = future;

    try {
      await future;
    } finally {
      if (identical(_ttsGenerationTail, future)) {
        _ttsGenerationTail = Future<void>.value();
      }
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed) {
      return;
    }

    final sanitized = text.trim();

    if (sanitized.isEmpty) {
      return;
    }

    /*
     * Capture the current generation before entering the async TTS
     * initialization path. stopSpeaking() can invalidate it while
     * initialization is in progress.
     */
    final generation = _ttsGeneration;

    /*
     * TTS is initialized only when the assistant actually needs
     * to speak. It is deliberately absent from initialize().
     */
    final ttsReady = await _ensureTtsInitialized();

    if (!ttsReady || _disposed) {
      logEvent(
        _tag,
        '[TTS_BLOCKED] engine unavailable',
      );

      return;
    }

    if (generation != _ttsGeneration) {
      logEvent(
        _tag,
        '[TTS_SKIPPED] '
        'reason=generation_changed_after_init '
        'generation=$generation '
        'currentGeneration=$_ttsGeneration',
      );
      return;
    }

    await _enqueueTtsGeneration(
      sanitized,
      generation: generation,
    );
  }

  @override
  Future<void> stopSpeaking() async {
    if (_disposed && !_audioPlayer.isPlaying) {
      return;
    }

    /*
     * Invalidate all queued TTS generations first.
     *
     * A currently executing synchronous OfflineTts.generate() cannot be
     * interrupted through the API used by this project, but once it
     * returns its PCM is discarded because its generation is stale.
     */
    _ttsGeneration++;

    logEvent(
      _tag,
      '[TTS_STOP_REQUESTED] '
      'generation=$_ttsGeneration',
    );

    try {
      _audioPlayer.stop();
    } catch (error) {
      logEvent(
        _tag,
        '[TTS_STOP_WARN] $error',
      );
    }

    _pendingTtsSamples = null;

    logEvent(
      _tag,
      '[TTS_STOP_COMPLETE] '
      'generation=$_ttsGeneration',
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    /*
     * Invalidate TTS generation before touching native resources.
     * Any queued generation will therefore refuse to use the TTS/audio
     * objects once its turn arrives.
     */
    _ttsGeneration++;

    /*
     * Mark disposed before touching native resources.
     * Any queued callback will therefore stop using the native
     * recognizer/stream/TTS.
     */
    _disposed = true;
    _isListening = false;
    _initialized = false;
    _ttsInitFuture = null;
    _bindingsInitFuture = null;
    _bindingsReady = false;

    /*
     * IMPORTANT ORDER:
     *
     * 1. invalidate TTS generation
     * 2. stop accepting audio
     * 3. cancel mic subscription
     * 4. stop recorder
     * 5. free OnlineStream
     * 6. free recognizer
     * 7. free TTS
     * 8. dispose audio player
     */
    await _closeMicSafely();
    await _closeAsrStreamSafely();

    try {
      _recognizer?.free();
    } catch (error) {
      logEvent(
        _tag,
        '[RECOGNIZER_FREE_WARN] $error',
      );
    }

    _recognizer = null;

    try {
      _tts?.free();
    } catch (error) {
      logEvent(
        _tag,
        '[TTS_FREE_WARN] $error',
      );
    }

    _tts = null;

    try {
      await _recorder.dispose();
    } catch (error) {
      logEvent(
        _tag,
        '[RECORDER_DISPOSE_WARN] $error',
      );
    }

    try {
      _audioPlayer.dispose();
    } catch (error) {
      logEvent(
        _tag,
        '[AUDIO_PLAYER_DISPOSE_WARN] $error',
      );
    }

    _pendingTtsSamples = null;

    _status = VoiceEngineStatus.unsupported(
      details: 'Engine disposed.',
    );
  }

  static Float32List _pcm16BytesToFloat32(
    Uint8List bytes,
  ) {
    final numSamples = bytes.length ~/ 2;

    if (numSamples <= 0) {
      return Float32List(0);
    }

    final samples = Float32List(numSamples);
    final byteData = ByteData.sublistView(bytes);

    for (var i = 0; i < numSamples; i++) {
      samples[i] =
          byteData.getInt16(
                i * 2,
                Endian.little,
              ) /
              32768.0;
    }

    return samples;
  }
}
