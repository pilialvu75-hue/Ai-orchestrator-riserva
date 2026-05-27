enum ModelManagementSection {
  voiceMultilingualStt,
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
  static const String _zipformerSttBaseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main';

  static const List<ModelManagementSection> sectionOrder =
      <ModelManagementSection>[
    ModelManagementSection.voiceMultilingualStt,
    ModelManagementSection.voiceItalian,
    ModelManagementSection.voiceFrench,
    ModelManagementSection.voiceEnglish,
  ];

  static const Map<ModelManagementSection, String> sectionTitles =
      <ModelManagementSection, String>{
    ModelManagementSection.voiceMultilingualStt:
        'Voice Engine - STT Zipformer',
    ModelManagementSection.voiceItalian: 'Voice Engine - Italiano',
    ModelManagementSection.voiceFrench: 'Voice Engine - Francese',
    ModelManagementSection.voiceEnglish: 'Voice Engine - Inglese',
  };

  static const List<RuntimeModelFileSpec> files = <RuntimeModelFileSpec>[
    RuntimeModelFileSpec(
      id: 'stt_zipformer_encoder',
      section: ModelManagementSection.voiceMultilingualStt,
      logicalName: 'Zipformer STT Encoder',
      fileName: 'encoder.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl: '$_zipformerSttBaseUrl/encoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 170 * 1024 * 1024,
      estimatedSizeLabel: '170MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_decoder',
      section: ModelManagementSection.voiceMultilingualStt,
      logicalName: 'Zipformer STT Decoder',
      fileName: 'decoder.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl: '$_zipformerSttBaseUrl/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 400 * 1024,
      estimatedSizeLabel: '400KB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_joiner',
      section: ModelManagementSection.voiceMultilingualStt,
      logicalName: 'Zipformer STT Joiner',
      fileName: 'joiner.onnx',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl: '$_zipformerSttBaseUrl/joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
      expectedBytes: 18 * 1024 * 1024,
      estimatedSizeLabel: '18MB',
    ),
    RuntimeModelFileSpec(
      id: 'stt_zipformer_tokens',
      section: ModelManagementSection.voiceMultilingualStt,
      logicalName: 'Zipformer STT Tokens',
      fileName: 'tokens.txt',
      relativeDirectory: 'models/stt_zipformer',
      downloadUrl: '$_zipformerSttBaseUrl/tokens.txt',
      expectedBytes: 7 * 1024,
      estimatedSizeLabel: '7KB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_model',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS TTS Italiano',
      fileName: 'vits-tts-it.onnx',
      relativeDirectory: 'models/it',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-it.onnx',
      expectedBytes: 132120576,
      estimatedSizeLabel: '126MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_lexicon',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS Lexicon Italiano',
      fileName: 'vits-tts-lexicon.txt',
      relativeDirectory: 'models/it',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-lexicon.txt',
      expectedBytes: 2097152,
      estimatedSizeLabel: '2MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_tts_tokens',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'VITS Tokens Italiano',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/it',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-tokens.txt',
      expectedBytes: 94208,
      estimatedSizeLabel: '92KB',
    ),
    RuntimeModelFileSpec(
      id: 'fr_tts_model',
      section: ModelManagementSection.voiceFrench,
      logicalName: 'VITS TTS Francese',
      fileName: 'vits-tts-fr.onnx',
      relativeDirectory: 'models/fr',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-fr.onnx',
      expectedBytes: 132120576,
      estimatedSizeLabel: '126MB',
    ),
    RuntimeModelFileSpec(
      id: 'fr_tts_lexicon',
      section: ModelManagementSection.voiceFrench,
      logicalName: 'VITS Lexicon Francese',
      fileName: 'vits-tts-lexicon.txt',
      relativeDirectory: 'models/fr',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-lexicon.txt',
      expectedBytes: 2097152,
      estimatedSizeLabel: '2MB',
    ),
    RuntimeModelFileSpec(
      id: 'fr_tts_tokens',
      section: ModelManagementSection.voiceFrench,
      logicalName: 'VITS Tokens Francese',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/fr',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-tokens.txt',
      expectedBytes: 94208,
      estimatedSizeLabel: '92KB',
    ),
    RuntimeModelFileSpec(
      id: 'en_tts_model',
      section: ModelManagementSection.voiceEnglish,
      logicalName: 'VITS TTS Inglese',
      fileName: 'vits-tts-en.onnx',
      relativeDirectory: 'models/en',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-en.onnx',
      expectedBytes: 132120576,
      estimatedSizeLabel: '126MB',
    ),
    RuntimeModelFileSpec(
      id: 'en_tts_lexicon',
      section: ModelManagementSection.voiceEnglish,
      logicalName: 'VITS Lexicon Inglese',
      fileName: 'vits-tts-lexicon.txt',
      relativeDirectory: 'models/en',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-lexicon.txt',
      expectedBytes: 2097152,
      estimatedSizeLabel: '2MB',
    ),
    RuntimeModelFileSpec(
      id: 'en_tts_tokens',
      section: ModelManagementSection.voiceEnglish,
      logicalName: 'VITS Tokens Inglese',
      fileName: 'vits-tts-tokens.txt',
      relativeDirectory: 'models/en',
      downloadUrl: 'https://pub-models.riconoscimento.ai/vits-tts-tokens.txt',
      expectedBytes: 94208,
      estimatedSizeLabel: '92KB',
    ),
  ];
}
