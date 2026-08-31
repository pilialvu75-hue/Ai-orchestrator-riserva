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

  static const List<ModelManagementSection>
      sectionOrder =
      <ModelManagementSection>[
    ModelManagementSection.voiceStt,
    ModelManagementSection.voiceTtsItalian,
  ];

  static const Map<ModelManagementSection, String>
      sectionTitles =
      <ModelManagementSection, String>{
    ModelManagementSection.voiceStt:
        'STT — Nemotron 3.5 0.6B Multilingual (streaming)',
    ModelManagementSection.voiceTtsItalian:
        'TTS — Piper Italiano (Paola Medium)',
  };

  static const List<RuntimeModelFileSpec>
      files =
      <RuntimeModelFileSpec>[
    // ── STT ────────────────────────────────────────────────────────────────
    //
    // Singolo archivio tar.bz2 contenente:
    //   encoder.int8.onnx
    //   decoder.int8.onnx
    //   joiner.int8.onnx
    //   tokens.txt
    //
    RuntimeModelFileSpec(
      id: 'stt_nemotron_archive',
      section:
          ModelManagementSection.voiceStt,
      logicalName:
          'Nemotron 3.5 0.6B Multilingual — '
          'Archivio completo',
      fileName:
          AppConstants.sttEncoderFile,
      downloadUrl:
          AppConstants.sttZipformerTarUrl,
      expectedBytes:
          AppConstants.sttZipformerTarExpectedBytes,
      estimatedSizeLabel: '~1.3 GB',
    ),

    // ── TTS ────────────────────────────────────────────────────────────────
    //
    // Contiene:
    //   it_IT-paola-medium.onnx
    //   tts-tokens.txt
    //   espeak-ng-data/
    //
    RuntimeModelFileSpec(
      id: 'it_tts_archive',
      section:
          ModelManagementSection.voiceTtsItalian,
      logicalName:
          'Piper TTS Italiano — '
          'Archivio Paola Medium',
      fileName:
          AppConstants.ttsModelFile,
      downloadUrl:
          AppConstants.ttsPaolaTarUrl,
      expectedBytes:
          AppConstants.ttsPaolaTarExpectedBytes,
      estimatedSizeLabel: '~63 MB',
    ),
  ];
}
