import 'package:ai_orchestrator/core/config/app/app_constants.dart';

enum ModelManagementSection {
  voiceBaseEnStt,
  voiceItalian,
  voiceFrench,
  voiceEnglish,
}

class RuntimeModelFileSpec {
  const RuntimeModelFileSpec({
    required this.id,
    required this.section,
    required this.logicalName,
    required this.fileName,
    required this.relativeDirectory,
    required this.downloadUrl,
    required this.expectedBytes,
    required this.estimatedSizeLabel,
  });

  final String id;
  final ModelManagementSection section;
  final String logicalName;
  final String fileName;
  final String relativeDirectory;
  final String downloadUrl;
  final int expectedBytes;
  final String estimatedSizeLabel;
}

class ModelRuntimeManifest {
  const ModelRuntimeManifest._();

  static const List<ModelManagementSection> sectionOrder =
      <ModelManagementSection>[
    ModelManagementSection.voiceBaseEnStt,
    ModelManagementSection.voiceItalian,
    ModelManagementSection.voiceFrench,
    ModelManagementSection.voiceEnglish,
  ];

  static const Map<ModelManagementSection, String> sectionTitles =
      <ModelManagementSection, String>{
    ModelManagementSection.voiceBaseEnStt:
        'Voice Engine - STT Zipformer (EN, streaming)',
    ModelManagementSection.voiceItalian: 'Voice Engine - Italiano',
    ModelManagementSection.voiceFrench: 'Voice Engine - Francese',
    ModelManagementSection.voiceEnglish: 'Voice Engine - Inglese',
  };

  static const List<RuntimeModelFileSpec> files = <RuntimeModelFileSpec>[
    RuntimeModelFileSpec(
      id: 'stt_zipformer_encoder',
      section: ModelManagementSection.voiceBaseEnStt,
      logicalName: 'Zipformer STT Encoder',
      fileName: 'encoder.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/encoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 170 * 1024 * 1024,
      estimatedSizeLabel: '170MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_decoder',
      section: ModelManagementSection.voiceBaseEnStt,
      logicalName: 'Zipformer STT Decoder',
      fileName: 'decoder.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 400 * 1024,
      estimatedSizeLabel: '400KB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_joiner',
      section: ModelManagementSection.voiceBaseEnStt,
      logicalName: 'Zipformer STT Joiner',
      fileName: 'joiner.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl:
          '${AppConstants.sttZipformerBaseUrl}/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 18 * 1024 * 1024,
      estimatedSizeLabel: '18MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_tokens',
      section: ModelManagementSection.voiceBaseEnStt,
      logicalName: 'Zipformer STT Tokens',
      fileName: 'tokens.txt',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl: '${AppConstants.sttZipformerBaseUrl}/tokens.txt',
      expectedBytes: 7 * 1024,
      estimatedSizeLabel: '7KB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_model',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS TTS Italiano',
      fileName: 'vits-tts-it.onnx',
      relativeDirectory: 'models/it',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/vits-tts-it-paola.onnx',
      expectedBytes: 120 * 1024 * 1024,
      estimatedSizeLabel: '120MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_lexicon',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS Lexicon Italiano',
      fileName: 'vits-tts-lexicon.txt',
      relativeDirectory: 'models/it',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/lexicon.txt',
      expectedBytes: 1 * 1024 * 1024,
      estimatedSizeLabel: '1MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_tokens',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS Tokens Italiano',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/it',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-tts-it-paola/tokens.txt',
      expectedBytes: 85 * 1024,
      estimatedSizeLabel: '85KB',
    ),
    // French MMS-VITS: character-level model, no lexicon required.
    RuntimeModelFileSpec(
      id: 'fr_tts_model',
      section: ModelManagementSection.voiceFrench,
      logicalName: 'VITS TTS Francese (MMS)',
      fileName: 'vits-tts-fr.onnx',
      relativeDirectory: 'models/fr',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-mms-fra/vits-mms-fra.onnx',
      expectedBytes: 125 * 1024 * 1024,
      estimatedSizeLabel: '125MB',
    ),
    RuntimeModelFileSpec(
      id: 'fr_tts_tokens',
      section: ModelManagementSection.voiceFrench,
      logicalName: 'VITS Tokens Francese',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/fr',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-mms-fra/tokens.txt',
      expectedBytes: 10 * 1024,
      estimatedSizeLabel: '10KB',
    ),
    // English MMS-VITS: character-level model, no lexicon required.
    RuntimeModelFileSpec(
      id: 'en_tts_model',
      section: ModelManagementSection.voiceEnglish,
      logicalName: 'VITS TTS Inglese (MMS)',
      fileName: 'vits-tts-en.onnx',
      relativeDirectory: 'models/en',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-mms-eng/vits-mms-eng.onnx',
      expectedBytes: 125 * 1024 * 1024,
      estimatedSizeLabel: '125MB',
    ),
    RuntimeModelFileSpec(
      id: 'en_tts_tokens',
      section: ModelManagementSection.voiceEnglish,
      logicalName: 'VITS Tokens Inglese',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/en',
      downloadUrl:
          'https://huggingface.co/csukuangfj/vits-models/resolve/main/vits-mms-eng/tokens.txt',
      expectedBytes: 10 * 1024,
      estimatedSizeLabel: '10KB',
    ),
  ];
}
