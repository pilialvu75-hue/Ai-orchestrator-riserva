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
   * TTS is intentionally lazy.
   *
   * Live must not initialize Piper/espeak together with the microphone.
   * This future also prevents two simultaneous speak() calls from
   * creating two native TTS instances.
   */
  Future<bool>? _ttsInitFuture;

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

  Future<bool> _initNativeBindings() async {
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

      final requiredPaths = <String, String>{
        AppConstants.sttEncoderFile: sttEncoderPath,
        AppConstants.sttDecoderFile: sttDecoderPath,
        AppConstants.sttJoinerFile: sttJoinerPath,
        AppConstants.sttTokensFile: sttTokensPath,
      };

      /*
       * IMPORTANT:
       *
       * Do not merely check exists && length > 0.
       *
       * The downloader already expects substantially larger assets.
       * A truncated encoder.onnx can otherwise pass validation and
       * make the native OnlineRecognizer abort during construction
       * or the first actual inference call.
       */
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

      /*
       * Breadcrumb immediately before entering native Sherpa code.
       *
       * If the process dies after this line and before STT_READY,
       * the native recognizer constructor is the next suspect.
       */
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
      final nativeReady = await _initNativeBindings();

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
       *
       * This prevents the microphone from being opened while two
       * independent ONNX workloads are being initialized in the
       * same process.
       */
      final sttReady = await _initializeStt();

      if (_disposed) {
        return _status;
      }

      final micReady = await _initializeMic();

      if (_disposed) {
        return _status;
      }

      /*
       * Live input depends on STT + microphone.
       * TTS is deliberately independent and lazy.
       */
      final initOk = sttReady;

      _initialized = initOk;

      _status = VoiceEngineStatus(
        engineId: sherpaOnnxEngineId,
        supportedPlatform: true,
        nativeLibrariesLoaded: true,
        microphonePermissionGranted: micReady,
        audioSessionReady: micReady,
        /*
         * TTS has not been loaded yet.
         */
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

            /*
             * Sherpa-ONNX streaming recognizers must only decode
             * when the stream reports that decoding is ready.
             *
             * Never call decode() unconditionally.
             */
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
            /*
             * Dart exceptions from the audio callback must never
             * escape the callback.
             *
             * Native SIGSEGV/SIGABRT is not catchable here, which
             * is why the breadcrumbs above are important.
             */
            logEvent(
              _tag,
              '[ASR_FRAME_FAIL] $error',
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
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

    /*
     * Stop accepting new frames first.
     *
     * Then cancel the subscription and stop the recorder.
     * Only after that do we release the native OnlineStream.
     */
    _isListening = false;

    await _closeMicSafely();
    await _closeAsrStreamSafely();
  }

  Future<void> _closeMicSafely() async {
    final subscription = _micSubscription;
    _micSubscription = null;

    if (subscription != null) {
      try {
        /*
         * cancel() completes after the subscription has finished
         * its pending stream cleanup. This must happen before
         * freeing the native OnlineStream.
         */
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
      /*
       * recorder.stop() can legitimately report that the recorder
       * is already stopped.
       */
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

    final tts = _tts;

    if (tts == null) {
      logEvent(
        _tag,
        '[TTS_BLOCKED] engine unavailable',
      );

      return;
    }

    try {
      final audio = tts.generate(
        text: sanitized,
        sid: 0,
        speed: _status.speechRate,
      );

      if (_disposed) {
        return;
      }

      _pendingTtsSamples = audio.samples;
      _pendingTtsSampleRate = audio.sampleRate;

      _audioPlayer.push(
        audio.samples,
        audio.sampleRate,
      );
    } catch (error) {
      logEvent(
        _tag,
        '[TTS_FAIL] $error',
      );
    }
  }

  @override
  Future<void> stopSpeaking() async {
    if (_disposed && !_audioPlayer.isPlaying) {
      return;
    }

    try {
      _audioPlayer.stop();
    } catch (error) {
      logEvent(
        _tag,
        '[TTS_STOP_WARN] $error',
      );
    }

    _pendingTtsSamples = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    /*
     * Mark disposed before touching native resources.
     * Any queued callback will therefore stop using the native
     * recognizer/stream.
     */
    _disposed = true;
    _isListening = false;
    _initialized = false;
    _ttsInitFuture = null;

    /*
     * IMPORTANT ORDER:
     *
     * 1. stop accepting audio
     * 2. cancel mic subscription
     * 3. stop recorder
     * 4. free OnlineStream
     * 5. free recognizer
     * 6. free TTS
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
