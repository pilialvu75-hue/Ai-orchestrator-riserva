import 'package:ai_orchestrator/core/config/app/app_constants.dart';

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
    // ── STT — archivio unico tar.bz2 da GitHub Releases ───────────────────
    // Tutti e 4 i file STT vengono estratti da un singolo archivio.
    // La UI mostra un solo elemento per sezione STT.
    RuntimeModelFileSpec(
      id: 'stt_zipformer_archive',
      section: ModelManagementSection.voiceStt,
      logicalName: 'Zipformer2 Transducer — Archivio completo',
      fileName: AppConstants.sttEncoderFile,
      downloadUrl: AppConstants.sttZipformerTarUrl,
      expectedBytes: AppConstants.sttZipformerTarExpectedBytes,
      estimatedSizeLabel: '~200 MB',
    ),
    // ── TTS — archivio unico tar.bz2 da GitHub Releases ───────────────────
    // Contiene: it_IT-paola-medium.onnx + tts-tokens.txt + espeak-ng-data/
    // Il download e l'estrazione avvengono tramite VoiceModelDownloader.
    RuntimeModelFileSpec(
      id: 'it_tts_archive',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName: 'Piper TTS Italiano — Archivio Paola Medium',
      fileName: AppConstants.ttsModelFile,
      downloadUrl: AppConstants.ttsPaolaTarUrl,
      expectedBytes: AppConstants.ttsPaolaTarExpectedBytes,
      estimatedSizeLabel: '~63 MB',
    ),
  ];
}
