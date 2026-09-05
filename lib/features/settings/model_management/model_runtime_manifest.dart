import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/voice/kokoro_assets.dart';

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
        'STT — Nemotron 3.5 0.6B Multilingual (streaming)',
    ModelManagementSection.voiceTtsItalian:
        'TTS — Kokoro (Italiano, Français, English)',
  };

  static const List<RuntimeModelFileSpec> files =
      <RuntimeModelFileSpec>[
    // ── STT ────────────────────────────────────────────────────────────────
    //
    // Nemotron 3.5 ASR Streaming 0.6B — 560 ms — INT8.
    //
    // Archivio ufficiale Sherpa-ONNX:
    //   encoder.int8.onnx
    //   decoder.int8.onnx
    //   joiner.int8.onnx
    //   tokens.txt
    //
    RuntimeModelFileSpec(
      id: 'stt_nemotron_archive',
      section: ModelManagementSection.voiceStt,
      logicalName:
          'Nemotron 3.5 0.6B Multilingual — Archivio completo',
      fileName: AppConstants.sttEncoderFile,
      downloadUrl: AppConstants.sttNemotronTarUrl,
      expectedBytes: AppConstants.sttNemotronTarExpectedBytes,
      estimatedSizeLabel: '~650 MB',
    ),

    // ── TTS ────────────────────────────────────────────────────────────────
    RuntimeModelFileSpec(
      id: 'it_tts_archive',
      section: ModelManagementSection.voiceTtsItalian,
      logicalName:
          'Kokoro — Italiano, Français, English',
      fileName: 'kokoro-v1_0-int8/verified.json',
      downloadUrl: KokoroAssets.archiveUrl,
      expectedBytes: KokoroAssets.archiveBytes,
      estimatedSizeLabel: '~132 MB download',
    ),
  ];
}
