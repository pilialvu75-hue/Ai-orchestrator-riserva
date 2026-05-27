import 'package:ai_orchestrator/core/config/app/app_constants.dart';

// Runtime voice-model sections currently managed by the in-app recovery page.
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
    this.fallbackDownloadUrl,
    required this.expectedBytes,
    required this.estimatedSizeLabel,
    this.requiredAtRuntime = true,
    this.downloadable = true,
    this.optionalCache = false,
  });

  final String id;
  final ModelManagementSection section;
  final String logicalName;
  final String fileName;
  final String downloadUrl;
  final String? fallbackDownloadUrl;
  final int expectedBytes;
  final String estimatedSizeLabel;
  final bool requiredAtRuntime;
  final bool downloadable;
  final bool optionalCache;

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
      fallbackDownloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/encoder-epoch-99-avg-1-chunk-16-left-128.onnx?download=true',
      expectedBytes: 170 * 1024 * 1024,
      estimatedSizeLabel: '~170 MB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_decoder',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Decoder',
      fileName: AppConstants.sttDecoderFile,
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      fallbackDownloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx?download=true',
      expectedBytes: 400 * 1024,
      estimatedSizeLabel: '~400 KB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_joiner',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Joiner',
      fileName: AppConstants.sttJoinerFile,
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
      fallbackDownloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx?download=true',
      expectedBytes: 18 * 1024 * 1024,
      estimatedSizeLabel: '~18 MB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_tokens',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Tokens',
      fileName: AppConstants.sttTokensFile,
      downloadUrl: '${AppConstants.sttZipformerBaseUrl}/tokens.txt',
      fallbackDownloadUrl: '${AppConstants.sttZipformerBaseUrl}/tokens.txt?download=true',
      expectedBytes: 7 * 1024,
      estimatedSizeLabel: '~7 KB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
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
      fallbackDownloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/vits-tts-it-paola.onnx?download=true',
      expectedBytes: 120 * 1024 * 1024,
      estimatedSizeLabel: '~120 MB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_lexicon',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'VITS TTS Italiano — Lessico',
      fileName: AppConstants.ttsLexiconFile,
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt',
      fallbackDownloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt?download=true',
      expectedBytes: 1 * 1024 * 1024,
      estimatedSizeLabel: '~1 MB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_tokens',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'VITS TTS Italiano — Tokens',
      fileName: AppConstants.ttsTokensFile,
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt',
      fallbackDownloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt?download=true',
      expectedBytes: 85 * 1024,
      estimatedSizeLabel: '~85 KB',
      requiredAtRuntime: true,
      downloadable: true,
      optionalCache: false,
    ),
  ];
}
