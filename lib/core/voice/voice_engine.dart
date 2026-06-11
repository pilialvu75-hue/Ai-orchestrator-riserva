import 'package:ai_orchestrator/core/config/app/app_constants.dart';

const String sherpaOnnxEngineId = 'sherpa-onnx';

typedef VoiceRecognitionResultCallback = void Function(
    String text, bool isFinal);

/// Holds the paths to all ONNX model files required by [SherpaOnnxVoiceEngine].
///
/// [ttsDataDir] sostituisce [ttsLexicon] per i modelli Piper che usano
/// espeak-ng-data invece di un lexicon.txt.
class VoiceModelPaths {
  const VoiceModelPaths({
    this.sttEncoder,
    this.sttDecoder,
    this.sttJoiner,
    this.sttTokens,
    this.ttsModel,
    this.ttsLexicon,
    this.ttsTokens,
    this.ttsDataDir,
  });

  final String? sttEncoder;
  final String? sttDecoder;
  final String? sttJoiner;
  final String? sttTokens;
  final String? ttsModel;

  /// Path al lexicon.txt — usato solo da modelli VITS non-Piper.
  /// Per i modelli Piper lasciare null e usare [ttsDataDir].
  final String? ttsLexicon;

  final String? ttsTokens;

  /// Path alla cartella espeak-ng-data — usato dai modelli Piper.
  /// Se valorizzato, ha precedenza su [ttsLexicon].
  final String? ttsDataDir;

  bool get hasSttPaths =>
      (sttEncoder?.isNotEmpty ?? false) &&
      (sttDecoder?.isNotEmpty ?? false) &&
      (sttJoiner?.isNotEmpty ?? false) &&
      (sttTokens?.isNotEmpty ?? false);

  bool get hasTtsPaths =>
      (ttsModel?.isNotEmpty ?? false) && (ttsTokens?.isNotEmpty ?? false);
}

/// Runtime status snapshot for a [VoiceEngine] implementation.
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
  final double speechRate;
  final bool enableLiveSubtitles;
  final String activeVoiceId;
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

  factory VoiceEngineStatus.unsupported({String? details}) {
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
