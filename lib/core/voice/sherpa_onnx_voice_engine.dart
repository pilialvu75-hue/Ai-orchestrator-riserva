import 'pcm_validation.dart';
import 'dart:async';
import 'dart:io';
import 'package:ai_orchestrator/core/voice/kokoro_assets.dart';

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
    String Function()? languageCode,
  }) : _modelPaths = modelPaths ?? const VoiceModelPaths(),
       _languageCode = languageCode ?? (() => 'it');

  final String Function() _languageCode;

  static const String _tag = 'VOICE_ENGINE';

  static const int _sampleRate = 16000;
  static const int _channels = 1;

  static const int _minSttEncoderBytes = 600 * 1024 * 1024;
  static const int _minSttDecoderBytes = 10 * 1024 * 1024;
  static const int _minSttJoinerBytes = 8 * 1024 * 1024;
  static const int _minSttTokensBytes = 64 * 1024;

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

  Future<bool>? _bindingsInitFuture;
  bool _bindingsReady = false;

  Future<bool>? _ttsInitFuture;

  Float32List? _pendingTtsSamples;
  int _pendingTtsSampleRate = 22050;

  @override
  bool get isListening => _isListening;

  @override
  bool get isSpeaking => _audioPlayer.isPlaying;

  Float32List? get pendingTtsSamples => _pendingTtsSamples;

  int get pendingTtsSampleRate => _pendingTtsSampleRate;

  // ---------------------------------------------------------------------------
  // FILE HELPERS
  // ---------------------------------------------------------------------------

  static bool _isReadableAssetFileSync(String path) {
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isValidSttAssetSync(String path, int minimumBytes) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return file.lengthSync() >= minimumBytes;
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

  static int _safeFileLengthSync(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return -1;
      return file.lengthSync();
    } catch (_) {
      return -1;
    }
  }

  static String _directorySnapshotSync(
    String path, {
    int maxEntries = 40,
  }) {
    try {
      final directory = Directory(path);

      if (!directory.existsSync()) {
        return 'missing';
      }

      final entities = directory.listSync(followLinks: false)
        ..sort(
          (a, b) => p.basename(a.path).compareTo(
                p.basename(b.path),
              ),
        );

      if (entities.isEmpty) {
        return 'empty';
      }

      final items = <String>[];

      for (final entity in entities.take(maxEntries)) {
        final name = p.basename(entity.path);

        if (entity is File) {
          var size = -1;

          try {
            size = entity.lengthSync();
          } catch (_) {}

          items.add('file:$name:$size');
        } else if (entity is Directory) {
          items.add('dir:$name');
        } else if (entity is Link) {
          items.add('link:$name');
        } else {
          items.add('other:$name');
        }
      }

      if (entities.length > maxEntries) {
        items.add(
          '...+${entities.length - maxEntries}_more',
        );
      }

      return items.join(',');
    } catch (error) {
      return 'snapshot_error:$error';
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

  // ---------------------------------------------------------------------------
  // STATUS
  // ---------------------------------------------------------------------------

  @override
  Future<VoiceEngineStatus> inspect() async {
    if (_disposed) {
      return VoiceEngineStatus.unsupported(
        details: 'Voice engine has been disposed.',
      );
    }
    return _status;
  }

  // ---------------------------------------------------------------------------
  // SHERPA BINDINGS
  // ---------------------------------------------------------------------------

  Future<bool> _ensureNativeBindings() async {
    if (_disposed) return false;
    if (_bindingsReady) return true;

    final inFlight = _bindingsInitFuture;
    if (inFlight != null) return inFlight;

    final future = _initializeNativeBindings();
    _bindingsInitFuture = future;

    try {
      final ready = await future;
      if (_disposed) return false;
      _bindingsReady = ready;
      return ready;
    } finally {
      if (identical(_bindingsInitFuture, future)) {
        _bindingsInitFuture = null;
      }
    }
  }

  Future<bool> _initializeNativeBindings() async {
    if (_disposed) return false;

    final supported = !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isWindows ||
            Platform.isLinux ||
            Platform.isMacOS);

    if (!supported) {
      const message =
          'Sherpa-ONNX voice engine is not supported on this platform.';
      logEvent(_tag, '[VOICE_UNSUPPORTED] $message');
      _status = VoiceEngineStatus.unsupported(details: message);
      return false;
    }

    // ── FIX: on Object cattura sia Exception che Error nativi ──
    try {
      sherpa_onnx.initBindings();
      logEvent(_tag, '[ONNX_BIND_OK]');
      return true;
    } on Object catch (error) {
      final message = 'Failed to load Sherpa-ONNX native libraries: $error';
      logEvent(_tag, '[ONNX_BIND_FAIL] $message');
      _status = VoiceEngineStatus.unsupported(details: message);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // STT
  // ---------------------------------------------------------------------------

  Future<bool> _initializeStt() async {
    if (_disposed) return false;

    // ── FIX: on Object cattura sia Exception che Error nativi ──
    try {
      final bindingsReady = await _ensureNativeBindings();
      if (!bindingsReady || _disposed) {
        logEvent(_tag, '[STT_BLOCKED] native bindings unavailable');
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

      if (!_isValidSttAssetSync(sttEncoderPath, _minSttEncoderBytes)) {
        invalid.add(
          '${AppConstants.sttEncoderFile}'
          '($sttEncoderPath, min=$_minSttEncoderBytes)',
        );
      }
      if (!_isValidSttAssetSync(sttDecoderPath, _minSttDecoderBytes)) {
        invalid.add(
          '${AppConstants.sttDecoderFile}'
          '($sttDecoderPath, min=$_minSttDecoderBytes)',
        );
      }
      if (!_isValidSttAssetSync(sttJoinerPath, _minSttJoinerBytes)) {
        invalid.add(
          '${AppConstants.sttJoinerFile}'
          '($sttJoinerPath, min=$_minSttJoinerBytes)',
        );
      }
      if (!_isValidSttAssetSync(sttTokensPath, _minSttTokensBytes)) {
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
        rule1MinTrailingSilence: AppConstants.sttRule1MinTrailingSilence,
        rule2MinTrailingSilence: AppConstants.sttRule2MinTrailingSilence,
        rule3MinUtteranceLength: AppConstants.sttRule3MinUtteranceLength,
      );

      logEvent(
        _tag,
        '[STT_BEFORE_RECOGNIZER_CREATE] '
        'model=nemotron-3.5 provider=cpu',
      );

      final recognizer = sherpa_onnx.OnlineRecognizer(recognizerConfig);

      if (_disposed) {
        try {
          recognizer.free();
        } catch (_) {}
        return false;
      }

      _recognizer = recognizer;
      logEvent(_tag, '[STT_READY] OnlineRecognizer ready');
      return true;
    } on Object catch (error) {
      final message = 'STT recognizer init failed: $error';
      logEvent(_tag, '[STT_INIT_FAIL] $message');
      _recognizer = null;
      return false;
    }
  }

  static String _normalizeSttLanguage(String localeId) {
    final normalized = localeId.trim().replaceAll('_', '-');
    if (normalized.isEmpty) return AppConstants.sttDefaultLanguage;
    return normalized;
  }

  // ---------------------------------------------------------------------------
  // TTS
  // ---------------------------------------------------------------------------

  Future<bool> _initializeTts() async {
    if (_disposed || !await _ensureNativeBindings()) return false;
    final assets = await KokoroAssets.verifiedPaths();
    if (_disposed) return false;
    if (assets == null) {
      logEvent(_tag, '[TTS_ASSETS_INVALID] Scarica o ripara Kokoro dal menu modelli vocali.');
      return false;
    }
    try {
      final config = sherpa_onnx.OfflineTtsConfig(
        model: sherpa_onnx.OfflineTtsModelConfig(
          kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
            model: assets['model']!,
            voices: assets['voices']!,
            tokens: assets['tokens']!,
            dataDir: assets['data']!,
            lang: 'it',
          ),
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
        maxNumSenetences: 1,
      );
      logEvent(_tag, '[TTS_NATIVE_CREATE_BEGIN] family=kokoro archive_verified=true');
      _tts = sherpa_onnx.OfflineTts(config);
      logEvent(_tag, '[TTS_NATIVE_CREATE_RETURNED] family=kokoro');
      return true;
    } on Object catch (error) {
      logEvent(_tag, '[TTS_INIT_FAIL] $error');
      return false;
    }
  }

  Future<bool> _ensureTtsInitialized() async {
    if (_disposed) return false;
    if (_tts != null) return true;

    final inFlight = _ttsInitFuture;
    if (inFlight != null) return inFlight;

    logEvent(_tag, '[TTS_LAZY_INIT]');

    final future = _initializeTts();
    _ttsInitFuture = future;

    try {
      final ready = await future;
      if (_disposed) return false;

      if (ready) {
        _status = _status.copyWith(
          speakerOutputReady: true,
          offlineTtsAvailable: true,
        );
        logEvent(_tag, '[TTS_LAZY_READY]');
      } else {
        logEvent(_tag, '[TTS_LAZY_FAIL]');
      }

      return ready;
    } finally {
      if (identical(_ttsInitFuture, future)) {
        _ttsInitFuture = null;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // MICROPHONE
  // ---------------------------------------------------------------------------

  Future<bool> _initializeMic() async {
    if (_disposed) return false;

    try {
      final hasPermission = await _recorder.hasPermission();
      if (_disposed) return false;
      logEvent(_tag, '[MIC_STATUS] permission=$hasPermission');
      return hasPermission;
    } on Object catch (error) {
      logEvent(_tag, '[MIC_STATUS_FAIL] $error');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // ENGINE INITIALIZATION
  // ---------------------------------------------------------------------------

  @override
  Future<VoiceEngineStatus> initialize() async {
    if (_disposed) {
      return VoiceEngineStatus.unsupported(
        details: 'Voice engine has been disposed.',
      );
    }

    if (_initialized) return _status;
    if (_initializing) return _status;

    _initializing = true;

    try {
      final nativeReady = await _ensureNativeBindings();
      if (!nativeReady || _disposed) return _status;

      final sttReady = await _initializeStt();
      if (_disposed) return _status;

      final micReady = await _initializeMic();
      if (_disposed) return _status;

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
        details:
            initOk ? null : 'Risorse vocali STT non disponibili.',
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
    } on Object catch (error) {
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

  // ---------------------------------------------------------------------------
  // LISTENING / ASR
  // ---------------------------------------------------------------------------

  @override
  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  }) async {
    if (_disposed) return;
    if (_isListening) return;

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

      if (_disposed) return;

      final hasPermission = await _recorder.hasPermission();

      if (!hasPermission || _disposed) {
        logEvent(
          _tag,
          '[ASR_BLOCKED] microphone unavailable',
        );
        return;
      }

     // final activeStream = recognizer.createStream();
    //  final language = _normalizeSttLanguage(localeId);

  //    try {
   //     activeStream.setOption(
  //        key: 'language',
   //       value: language,
//        );

 //       logEvent(
   //       _tag,
  //        '[ASR_LANGUAGE_SET] '
   //       'locale=$localeId '
   //       'language=$language',
   //     );
   //   } on Object catch (error) {
  //      try {
  //        activeStream.free();
   //     } catch (_) {}

   //     logEvent(
   //       _tag,
   //       '[ASR_LANGUAGE_SET_FAIL] '
    //      'language=$language '
    //      'error=$error',
     //   );

      //  return;
   //   }
final activeStream = recognizer.createStream();
final language = _normalizeSttLanguage(localeId);

logEvent(
  _tag,
  '[ASR_LANGUAGE_SET_SKIPPED] '
  'locale=$localeId '
  'language=$language '
  'reason=sherpa_onnx_1.10.2_compatibility_test',
);
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
        '[ASR_STARTED] '
        'sampleRate=$_sampleRate '
        'language=$language',
      );

      _micSubscription = audioStream.listen(
        (Uint8List bytes) {
          if (_disposed || !_isListening) return;

          try {
            if (bytes.length < 2) return;

            final stream = _asrStream;
            if (stream == null) return;

            final samples = _pcm16BytesToFloat32(bytes);
            if (samples.isEmpty) return;

            stream.acceptWaveform(
              samples: samples,
              sampleRate: _sampleRate,
            );

            while (recognizer.isReady(stream)) {
              recognizer.decode(stream);
            }

            if (recognizer.isEndpoint(stream)) {
              final result = recognizer.getResult(stream);
              final text = result.text.trim();

              if (text.isNotEmpty) {
                logEvent(
                  _tag,
                  '[ASR_FINAL] chars=${text.length}',
                );

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
          } on Object catch (error) {
            logEvent(
              _tag,
              '[ASR_FRAME_FAIL] $error',
            );
          }
        },
        onError: (Object error) {
          if (_disposed) return;

          logEvent(
            _tag,
            '[MIC_STREAM_ERROR] $error',
          );

          _isListening = false;
        },
        onDone: () {
          if (_disposed) return;

          _isListening = false;

          logEvent(
            _tag,
            '[MIC_STREAM_DONE]',
          );
        },
        cancelOnError: false,
      );
    } on Object catch (error) {
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
    if (_disposed && !_isListening) return;

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
      } on Object catch (error) {
        logEvent(
          _tag,
          '[MIC_CANCEL_WARN] $error',
        );
      }
    }

    try {
      await _recorder.stop();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[MIC_STOP_WARN] $error',
      );
    }
  }

  Future<void> _closeAsrStreamSafely() async {
    final stream = _asrStream;
    _asrStream = null;

    if (stream == null) return;

    try {
      stream.free();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[ASR_STREAM_FREE_WARN] $error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // TTS
  // ---------------------------------------------------------------------------

  @override
  Future<void> speak(String text) async {
    if (_disposed) return;

    final sanitized = text.trim();
    if (sanitized.isEmpty) return;

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
      final language = _languageCode().split(RegExp('[-_]')).first;
      final lang = const ['it', 'fr', 'en'].contains(language) ? language : 'en';
      // IDs belong to the pinned official v1.0 bundle: Sara, Siwis, Heart.
      final sid = lang == 'it' ? 35 : (lang == 'fr' ? 30 : 3);
      final speed = _status.speechRate;
      if (!speed.isFinite || speed <= 0) {
        throw StateError('Invalid TTS speech rate: $speed');
      }
      logEvent(
        _tag,
        '[TTS_GENERATE_BEGIN] family=kokoro lang=$lang sid=$sid '
        'speed=$speed chars=${sanitized.length}',
      );
      final audio = tts.generateWithConfig(
        text: sanitized,
        config: sherpa_onnx.OfflineTtsGenerationConfig(
          sid: sid,
          speed: speed,
          extra: {'lang': lang},
        ),
      );

      if (_disposed) return;

      validatePcm(audio.samples, audio.sampleRate);
      _pendingTtsSamples = audio.samples;
      _pendingTtsSampleRate = audio.sampleRate;

      logEvent(
        _tag,
        '[TTS_AUDIO_READY] '
        'samples=${audio.samples.length} '
        'sampleRate=${audio.sampleRate}',
      );

      _audioPlayer.push(
        audio.samples,
        audio.sampleRate,
      );
    } on Object catch (error) {
      logEvent(
        _tag,
        '[TTS_FAIL] $error',
      );
      _pendingTtsSamples = null;
      rethrow;
    }
  }

  @override
  Future<void> stopSpeaking() async {
    if (_disposed && !_audioPlayer.isPlaying) return;

    try {
      _audioPlayer.stop();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[TTS_STOP_WARN] $error',
      );
    }

    _pendingTtsSamples = null;
  }

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------

  @override
  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;
    _isListening = false;
    _initialized = false;
    _ttsInitFuture = null;
    _bindingsInitFuture = null;
    _bindingsReady = false;

    await _closeMicSafely();
    await _closeAsrStreamSafely();

    try {
      _recognizer?.free();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[RECOGNIZER_FREE_WARN] $error',
      );
    }

    _recognizer = null;

    try {
      _tts?.free();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[TTS_FREE_WARN] $error',
      );
    }

    _tts = null;

    try {
      await _recorder.dispose();
    } on Object catch (error) {
      logEvent(
        _tag,
        '[RECORDER_DISPOSE_WARN] $error',
      );
    }

    try {
      _audioPlayer.dispose();
    } on Object catch (error) {
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

  // ---------------------------------------------------------------------------
  // PCM CONVERSION
  // ---------------------------------------------------------------------------

  static Float32List _pcm16BytesToFloat32(Uint8List bytes) {
    final numSamples = bytes.length ~/ 2;

    if (numSamples <= 0) {
      return Float32List(0);
    }

    final samples = Float32List(numSamples);
    final byteData = ByteData.sublistView(bytes);

    for (var i = 0; i < numSamples; i++) {
      samples[i] =
          byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }

    return samples;
  }
}
