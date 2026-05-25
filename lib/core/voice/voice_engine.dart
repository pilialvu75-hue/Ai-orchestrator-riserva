import 'package:ai_orchestrator/core/config/app/app_constants.dart';

const String sherpaOnnxEngineId = 'sherpa-onnx';

typedef VoiceRecognitionResultCallback = void Function(String text, bool isFinal);

/// Holds the paths to all ONNX model files required by [SherpaOnnxVoiceEngine].
///
/// All fields are nullable so that the engine can be constructed early and
/// report a clear diagnostic when a path is absent rather than crashing.
class VoiceModelPaths {
  const VoiceModelPaths({
    this.sttEncoder,
    this.sttDecoder,
    this.sttJoiner,
    this.sttTokens,
    this.ttsModel,
    this.ttsLexicon,
    this.ttsTokens,
  });

  /// Path to the streaming-transducer encoder ONNX file.
  final String? sttEncoder;

  /// Path to the streaming-transducer decoder ONNX file.
  final String? sttDecoder;

  /// Path to the streaming-transducer joiner ONNX file.
  final String? sttJoiner;

  /// Path to the STT vocabulary tokens file.
  final String? sttTokens;

  /// Path to the VITS TTS model ONNX file.
  final String? ttsModel;

  /// Path to the VITS lexicon file (may be empty string for char-based models).
  final String? ttsLexicon;

  /// Path to the TTS vocabulary tokens file.
  final String? ttsTokens;

  /// Returns `true` when all required STT files are non-null and non-empty.
  bool get hasSttPaths =>
      (sttEncoder?.isNotEmpty ?? false) &&
      (sttDecoder?.isNotEmpty ?? false) &&
      (sttJoiner?.isNotEmpty ?? false) &&
      (sttTokens?.isNotEmpty ?? false);

  /// Returns `true` when the minimum required TTS files are non-null and
  /// non-empty.
  bool get hasTtsPaths =>
      (ttsModel?.isNotEmpty ?? false) && (ttsTokens?.isNotEmpty ?? false);
}

/// Runtime status snapshot for a [VoiceEngine] implementation.
///
/// Extended in Phase 1 with settings-layer payload fields ([speechRate],
/// [enableLiveSubtitles], [activeVoiceId], [isVoiceDownloaded]) so that the
/// settings UI can surface voice controls without a separate settings model.
class VoiceEngineStatus {
  const VoiceEngineStatus({
    required this.engineId,
    required this.supportedPlatform,
    required this.nativeLibrariesLoaded,
    required this.microphonePermissionGranted,
    required this.audioSessionReady,
    required this.speakerOutputReady,
    required this.initialized,
    required this.offlineAsrAvailable,
    required this.offlineTtsAvailable,
    this.details,
    // ── Settings-layer payload (Step 6) ────────────────────────────────────
    this.speechRate = 1.0,
    this.enableLiveSubtitles = false,
    this.activeVoiceId = '',
    this.isVoiceDownloaded = false,
  });

  final String engineId;
  final bool supportedPlatform;
  final bool nativeLibrariesLoaded;
  final bool microphonePermissionGranted;
  final bool audioSessionReady;
  final bool speakerOutputReady;
  final bool initialized;
  final bool offlineAsrAvailable;
  final bool offlineTtsAvailable;
  final String? details;

  /// TTS playback speed multiplier (1.0 = normal speed).
  final double speechRate;

  /// When `true`, the live-session loop emits real-time subtitles.
  final bool enableLiveSubtitles;

  /// Identifier of the active TTS voice / speaker model.
  final String activeVoiceId;

  /// `true` when the ONNX voice model file is present on local storage.
  final bool isVoiceDownloaded;

  bool get readyForInput =>
      initialized &&
      supportedPlatform &&
      nativeLibrariesLoaded &&
      microphonePermissionGranted &&
      audioSessionReady &&
      offlineAsrAvailable;

  bool get readyForOutput =>
      initialized &&
      supportedPlatform &&
      nativeLibrariesLoaded &&
      audioSessionReady &&
      speakerOutputReady &&
      offlineTtsAvailable;

  factory VoiceEngineStatus.unsupported({
    String? details,
  }) {
    return VoiceEngineStatus(
      engineId: sherpaOnnxEngineId,
      supportedPlatform: false,
      nativeLibrariesLoaded: false,
      microphonePermissionGranted: false,
      audioSessionReady: false,
      speakerOutputReady: false,
      initialized: false,
      offlineAsrAvailable: false,
      offlineTtsAvailable: false,
      details: details,
    );
  }

  factory VoiceEngineStatus.fromMap(Map<Object?, Object?> map) {
    bool readBool(String key) => map[key] == true;

    return VoiceEngineStatus(
      engineId: map['engineId'] as String? ?? sherpaOnnxEngineId,
      supportedPlatform: readBool('supportedPlatform'),
      nativeLibrariesLoaded: readBool('nativeLibrariesLoaded'),
      microphonePermissionGranted: readBool('microphonePermissionGranted'),
      audioSessionReady: readBool('audioSessionReady'),
      speakerOutputReady: readBool('speakerOutputReady'),
      initialized: readBool('initialized'),
      offlineAsrAvailable: readBool('offlineAsrAvailable'),
      offlineTtsAvailable: readBool('offlineTtsAvailable'),
      details: map['details'] as String?,
      speechRate: (map['speechRate'] as num?)?.toDouble() ?? 1.0,
      enableLiveSubtitles: readBool('enableLiveSubtitles'),
      activeVoiceId: map['activeVoiceId'] as String? ?? '',
      isVoiceDownloaded: readBool('isVoiceDownloaded'),
    );
  }

  /// Returns a copy of this status with updated settings-layer fields.
  VoiceEngineStatus copyWithSettings({
    double? speechRate,
    bool? enableLiveSubtitles,
    String? activeVoiceId,
    bool? isVoiceDownloaded,
  }) {
    return VoiceEngineStatus(
      engineId: engineId,
      supportedPlatform: supportedPlatform,
      nativeLibrariesLoaded: nativeLibrariesLoaded,
      microphonePermissionGranted: microphonePermissionGranted,
      audioSessionReady: audioSessionReady,
      speakerOutputReady: speakerOutputReady,
      initialized: initialized,
      offlineAsrAvailable: offlineAsrAvailable,
      offlineTtsAvailable: offlineTtsAvailable,
      details: details,
      speechRate: speechRate ?? this.speechRate,
      enableLiveSubtitles: enableLiveSubtitles ?? this.enableLiveSubtitles,
      activeVoiceId: activeVoiceId ?? this.activeVoiceId,
      isVoiceDownloaded: isVoiceDownloaded ?? this.isVoiceDownloaded,
    );
  }
}

abstract class VoiceEngine {
  Future<VoiceEngineStatus> inspect();

  Future<VoiceEngineStatus> initialize();

  bool get isListening;

  bool get isSpeaking;

  Future<void> startListening({
    required VoiceRecognitionResultCallback onResult,
    String localeId = AppConstants.sttDefaultLocaleId,
  });

  Future<void> stopListening();

  Future<void> speak(String text);

  Future<void> stopSpeaking();

  Future<void> dispose();
}
