const String sherpaOnnxEngineId = 'sherpa-onnx';

typedef VoiceRecognitionResultCallback = void Function(String text, bool isFinal);

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
    String localeId = 'en_US',
  });

  Future<void> stopListening();

  Future<void> speak(String text);

  Future<void> stopSpeaking();

  Future<void> dispose();
}
