import 'package:ai_orchestrator/core/config/app/app_constants.dart';

// Runtime-supported Voice Engine sections.
// NOTE: Only the sections below reflect the ACTUAL current runtime architecture:
//   - voiceStt: Sherpa-ONNX streaming Zipformer2 transducer (English, online)
//   - voiceTtsItalian: VITS ONNX TTS for Italian (Paola), the active TTS voice
// Additional TTS languages (FR, EN) are NOT currently loaded by the runtime
// and are intentionally excluded to keep the manifest consistent with reality.
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

  // All voice model files are stored flat in the private models directory
  // (appDir/models/<fileName>).  There is no subdirectory layering so that
  // VoiceModelDownloader, ModelManagementService, and SherpaOnnxVoiceEngine
  // all resolve to the same on-disk paths.
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
        'TTS — VITS Italiano (Paola)',
  };

  static const List<RuntimeModelFileSpec> files = <RuntimeModelFileSpec>[
    // ── Zipformer2 streaming transducer — STT ──────────────────────────────
    // Source: csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26
    // Architecture: Online Zipformer2 transducer (encoder + decoder + joiner)
    // Language: English (EN-only; multilingual streaming Zipformer is not
    //   available as of mid-2025).
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
    // ── VITS TTS — Italiano (Paola) ────────────────────────────────────────
    // Source: csukuangfj/vits-models — vits-tts-it-paola
    // Architecture: VITS ONNX offline TTS
    // Language: Italian (lexicon-based; requires lexicon + tokens).
    RuntimeModelFileSpec(
      id: 'it_tts_model',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'VITS TTS Italiano — Modello',
      fileName: AppConstants.ttsModelFile,
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/vits-tts-it-paola.onnx',
      expectedBytes: 120 * 1024 * 1024,
      estimatedSizeLabel: '~120 MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_lexicon',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'VITS TTS Italiano — Lessico',
      fileName: AppConstants.ttsLexiconFile,
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt',
      expectedBytes: 1 * 1024 * 1024,
      estimatedSizeLabel: '~1 MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_tokens',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'VITS TTS Italiano — Tokens',
      fileName: AppConstants.ttsTokensFile,
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt',
      expectedBytes: 85 * 1024,
      estimatedSizeLabel: '~85 KB',
    ),
  ];
}
