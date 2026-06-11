import 'package:ai_orchestrator/core/config/app/app_constants.dart';

// Runtime-supported Voice Engine sections.
// NOTE: Only the sections below reflect the ACTUAL current runtime architecture:
//   - voiceStt: Sherpa-ONNX streaming Zipformer2 transducer (English, online)
//   - voiceTtsItalian: VITS Piper TTS for Italian (Paola), the active TTS voice
// Il modello TTS Piper viene distribuito come archivio tar.bz2 e usa
// espeak-ng-data invece di lexicon.txt. Non ci sono più file individuali
// per il TTS nel manifest — il download avviene tramite VoiceModelDownloader.
enum ModelManagementSection {
  voiceStt,
  voiceTtsItalian,
}

class RuntimeModelFileSpec {
  const RuntimeModelFileSpec({
    required this.id,
    required this.section,
    required this.logicalName,
    required this.fileName,
    required this.downloadUrl,
    required this.expectedBytes,
    required this.estimatedSizeLabel,
  });

  final String id;
  final ModelManagementSection section;
  final String logicalName;
  final String fileName;
  final String downloadUrl;
  final int expectedBytes;
  final String estimatedSizeLabel;

  String get relativeDirectory => '';
}

class ModelRuntimeManifest {
  const ModelRuntimeManifest._();

  static const List<ModelManagementSection> sectionOrder =
      <ModelManagementSection>[
    ModelManagementSection.voiceStt,
    ModelManagementSection.voiceTtsItalian,
  ];

  static const Map<ModelManagementSection, String> sectionTitles =
      <ModelManagementSection, String>{
    ModelManagementSection.voiceStt:
        'STT — Zipformer2 Transducer (EN streaming)',
    ModelManagementSection.voiceTtsItalian:
        'TTS — Piper Italiano (Paola Medium)',
  };

  static const List<RuntimeModelFileSpec> files = <RuntimeModelFileSpec>[
    // ── Zipformer2 streaming transducer — STT ──────────────────────────────
    // Source: csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26
    // Architecture: Online Zipformer2 transducer (encoder + decoder + joiner)
    // Language: English (EN-only)
    RuntimeModelFileSpec(
      id: 'stt_zipformer_encoder',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Encoder',
      fileName: AppConstants.sttEncoderFile,
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/encoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 170 * 1024 * 1024,
      estimatedSizeLabel: '~170 MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_decoder',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Decoder',
      fileName: AppConstants.sttDecoderFile,
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 400 * 1024,
      estimatedSizeLabel: '~400 KB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_joiner',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Joiner',
      fileName: AppConstants.sttJoinerFile,
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 18 * 1024 * 1024,
      estimatedSizeLabel: '~18 MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_tokens',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Tokens',
      fileName: AppConstants.sttTokensFile,
      downloadUrl: '${AppConstants.sttZipformerBaseUrl}/tokens.txt',
      expectedBytes: 7 * 1024,
      estimatedSizeLabel: '~7 KB',
    ),
    // ── Piper TTS — Italiano (Paola Medium) ───────────────────────────────
    // Source: github.com/k2-fsa/sherpa-onnx releases/tts-models
    // Archive: vits-piper-it_IT-paola-medium.tar.bz2 (~63 MB)
    // Contiene: it_IT-paola-medium.onnx + tokens.txt + espeak-ng-data/
    // Il download e l'estrazione avvengono tramite VoiceModelDownloader.
    // Qui listiamo solo il file principale come riferimento UI.
    RuntimeModelFileSpec(
      id: 'it_tts_model',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'Piper TTS Italiano — Archivio Paola Medium',
      fileName: AppConstants.ttsModelFile,
      downloadUrl: AppConstants.ttsPaolaTarUrl,
      expectedBytes: AppConstants.ttsPaolaTarExpectedBytes,
      estimatedSizeLabel: '~63 MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_tokens',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'Piper TTS Italiano — Tokens',
      fileName: AppConstants.ttsTokensFile,
      downloadUrl: AppConstants.ttsPaolaTarUrl,
      expectedBytes: AppConstants.ttsPaolaTarExpectedBytes,
      estimatedSizeLabel: 'incluso nell\'archivio',
    ),
  ];
}
