enum ModelManagementSection {
  linguisticModel,
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
    ModelManagementSection.linguisticModel,
    ModelManagementSection.voiceItalian,
    ModelManagementSection.voiceFrench,
    ModelManagementSection.voiceEnglish,
  ];

  static const Map<ModelManagementSection, String> sectionTitles =
      <ModelManagementSection, String>{
    ModelManagementSection.linguisticModel: 'Modello Linguistico',
    ModelManagementSection.voiceItalian: 'Voice Engine - Italiano',
    ModelManagementSection.voiceFrench: 'Voice Engine - Francese',
    ModelManagementSection.voiceEnglish: 'Voice Engine - Inglese',
  };

  static const List<RuntimeModelFileSpec> files = <RuntimeModelFileSpec>[
    RuntimeModelFileSpec(
      id: 'llm_tinyllama_q4km',
      section: ModelManagementSection.linguisticModel,
      logicalName: 'TinyLlama 1.1B Chat GGUF',
      fileName: 'tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
      relativeDirectory: 'models',
      downloadUrl:
          'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf?download=true',
      expectedBytes: 669000000,
      estimatedSizeLabel: '638MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_stt_model',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'Whisper STT Italiano',
      fileName: 'whisper-tiny-en.onnx',
      relativeDirectory: 'models/it',
      downloadUrl: 'https://pub-models.riconoscimento.ai/whisper-tiny-en.onnx',
      expectedBytes: 81788928,
      estimatedSizeLabel: '78MB',
    ),
    RuntimeModelFileSpec(
      id: 'it_stt_tokens',
      section: ModelManagementSection.voiceItalian,
      logicalName: 'Whisper STT Tokens',
      fileName: 'whisper-tiny-en-tokens.txt',
      relativeDirectory: 'models/it',
      downloadUrl:
          'https://pub-models.riconoscimento.ai/whisper-tiny-en-tokens.txt',
      expectedBytes: 49152,
      estimatedSizeLabel: '48KB',
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
