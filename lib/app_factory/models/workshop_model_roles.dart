import 'package:flutter/foundation.dart';

/// Logical AI roles used by the Workshop and the Assistant.
///
/// A role is deliberately independent from a concrete runtime implementation.
/// This allows the model assigned to a role to be changed without modifying
/// the Workshop pipeline.
enum AppAiRole {
  assistantOrchestrator,
  workshopOrchestrator,
  architect,
  engineer,
  reviewer,
}

extension AppAiRoleLabel on AppAiRole {
  String get label {
    switch (this) {
      case AppAiRole.assistantOrchestrator:
        return 'Assistente / Hannibal';
      case AppAiRole.workshopOrchestrator:
        return 'Cantiere / Orchestratore';
      case AppAiRole.architect:
        return 'Cantiere / Architetto';
      case AppAiRole.engineer:
        return 'Cantiere / Ingegnere';
      case AppAiRole.reviewer:
        return 'Cantiere / Reviewer';
    }
  }

  String get id {
    switch (this) {
      case AppAiRole.assistantOrchestrator:
        return 'assistant_orchestrator';
      case AppAiRole.workshopOrchestrator:
        return 'workshop_orchestrator';
      case AppAiRole.architect:
        return 'architect';
      case AppAiRole.engineer:
        return 'engineer';
      case AppAiRole.reviewer:
        return 'reviewer';
    }
  }
}

/// Runtime source from which a model can be supplied.
enum AiModelSource {
  local,
  cloud,
}

/// Description of a model that can be assigned to an AI role.
///
/// This class contains only model identity and capability metadata.
/// Downloading, verification, persistence and runtime loading remain the
/// responsibility of the existing model-management infrastructure.
@immutable
class WorkshopModelDescriptor {
  const WorkshopModelDescriptor({
    required this.id,
    required this.displayName,
    required this.repository,
    required this.filename,
    required this.quantization,
    required this.sizeBytes,
    required this.source,
    required this.roles,
    required this.downloadUrl,
    this.optional = false,
  });

  final String id;
  final String displayName;

  /// Hugging Face repository identifier, e.g. `Qwen/...`.
  final String repository;

  /// Concrete GGUF file selected for the initial configuration.
  final String filename;

  final String quantization;

  /// Approximate model-file size.
  ///
  /// This is metadata used by the model manager/UI. The existing model
  /// verification system remains authoritative for the actual downloaded file.
  final int sizeBytes;

  final AiModelSource source;

  final Set<AppAiRole> roles;

  /// Direct HTTPS URL to the selected model file.
  ///
  /// The application should pass this to the existing model downloader rather
  /// than implementing another download mechanism here.
  final String downloadUrl;

  /// Optional models are visible in the catalogue but are not required for
  /// the default Workshop installation.
  final bool optional;

  bool canServe(AppAiRole role) => roles.contains(role);
}

/// Initial Workshop/Assistant model catalogue.
///
/// IMPORTANT:
/// - This is a catalogue, not a downloader.
/// - Do not duplicate the existing ModelManagementService here.
/// - The existing model-management system remains responsible for download,
///   verification, persistence, import/export and runtime loading.
/// - The UI will eventually allow the user to assign any compatible model to
///   any role.
abstract final class WorkshopModelCatalogue {
  static const WorkshopModelDescriptor assistantPhi35 =
      WorkshopModelDescriptor(
    id: 'phi3_5_mini',
    displayName: 'Phi-3.5 Mini Instruct',
    repository: 'tensorblock/Phi-3.5-mini-instruct-GGUF',
    filename: 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 2229000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.assistantOrchestrator,
    },
    downloadUrl:
        'https://huggingface.co/tensorblock/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
  );

  static const WorkshopModelDescriptor workshopOrchestrator =
      WorkshopModelDescriptor(
    id: 'qwen2_5_3b_instruct',
    displayName: 'Qwen2.5 3B Instruct',
    repository: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
    filename: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 2000000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.workshopOrchestrator,
    },
    downloadUrl:
        'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
  );

  static const WorkshopModelDescriptor architect =
      WorkshopModelDescriptor(
    id: 'qwen2_5_coder_1_5b_instruct',
    displayName: 'Qwen2.5-Coder 1.5B Instruct',
    repository: 'Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF',
    filename: 'qwen2.5-coder-1.5b-instruct-q5_k_m.gguf',
    quantization: 'Q5_K_M',
    sizeBytes: 1290000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.architect,
    },
    downloadUrl:
        'https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q5_k_m.gguf',
  );

  static const WorkshopModelDescriptor engineer =
      WorkshopModelDescriptor(
    id: 'qwen2_5_coder_7b_instruct',
    displayName: 'Qwen2.5-Coder 7B Instruct',
    repository: 'Qwen/Qwen2.5-Coder-7B-Instruct-GGUF',
    filename: 'qwen2.5-coder-7b-instruct-q4_k_m.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 4680000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.engineer,
    },
  );

  static const WorkshopModelDescriptor reviewer =
      WorkshopModelDescriptor(
    id: 'starcoder2_3b',
    displayName: 'StarCoder2 3B',
    repository: 'tensorblock/starcoder2-3b-GGUF',
    filename: 'starcoder2-3b-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 1758000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/tensorblock/starcoder2-3b-GGUF/resolve/main/starcoder2-3b-Q4_K_M.gguf',
  );

  /// Optional stronger Engineer model.
  ///
  /// It is intentionally not the default because the Q4_K_M file is about
  /// 9.65 GB and is therefore a substantial local workload on a phone.
  static const WorkshopModelDescriptor deepSeekEngineer =
      WorkshopModelDescriptor(
    id: 'deepseek_coder_v2_lite_instruct',
    displayName: 'DeepSeek Coder V2 Lite Instruct',
    repository: 'tensorblock/DeepSeek-Coder-V2-Lite-Instruct-GGUF',
    filename: 'DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 9653000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.engineer,
    },
    downloadUrl:
        'https://huggingface.co/tensorblock/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf',
    optional: true,
  );

  static const List<WorkshopModelDescriptor> all =
      <WorkshopModelDescriptor>[
    assistantPhi35,
    workshopOrchestrator,
    architect,
    engineer,
    reviewer,
    deepSeekEngineer,
  ];

  static WorkshopModelDescriptor? findById(String id) {
    for (final model in all) {
      if (model.id == id) {
        return model;
      }
    }
    return null;
  }

  static List<WorkshopModelDescriptor> forRole(AppAiRole role) {
    return all
        .where((model) => model.canServe(role))
        .toList(growable: false);
  }
}
