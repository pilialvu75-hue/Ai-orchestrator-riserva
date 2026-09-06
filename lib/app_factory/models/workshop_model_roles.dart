import 'package:flutter/foundation.dart';

/// Logical AI roles used by the Workshop and the Assistant.
///
/// A role is deliberately independent from a concrete runtime implementation.
/// The Assistant has its own role and configuration; the Workshop has its own
/// four technical roles.
///
/// Workshop role selection must never inherit the Assistant selected model.
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
/// This class contains only identity/capability metadata.
/// Downloading, persistence and runtime loading remain the responsibility of
/// the existing model-management infrastructure.
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
  final String repository;
  final String filename;
  final String quantization;
  final int sizeBytes;
  final AiModelSource source;
  final Set<AppAiRole> roles;
  final String downloadUrl;
  final bool optional;

  bool canServe(AppAiRole role) => roles.contains(role);

  bool get isWorkshopModel {
    return roles.any(
      (role) => role != AppAiRole.assistantOrchestrator,
    );
  }
}

/// Workshop model catalogue.
///
/// IMPORTANT:
/// - The Assistant model is kept in the shared catalogue only so the common
///   storage/runtime infrastructure can recognise the physical GGUF.
/// - The Workshop UI MUST NOT present assistant-only entries.
/// - Every Workshop-capable model can be selected independently for each of
///   the four Workshop roles.
/// - The physical model file can still be shared with the Assistant/storage
///   subsystem.
/// - Selection is a Workshop concern, not an Assistant concern.
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
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
  );

  static const WorkshopModelDescriptor architect =
      WorkshopModelDescriptor(
    id: 'qwen2_5_coder_7b_instruct',
    displayName: 'Qwen2.5-Coder 7B Instruct',
    repository: 'Qwen/Qwen2.5-Coder-7B-Instruct-GGUF',
    filename: 'qwen2.5-coder-7b-instruct-q4_k_m.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 4680000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf',
  );

  static const WorkshopModelDescriptor engineer =
      WorkshopModelDescriptor(
    id: 'deepseek_coder_6_7b_instruct',
    displayName: 'DeepSeek Coder 6.7B Instruct',
    repository: 'second-state/Deepseek-Coder-6.7B-Instruct-GGUF',
    filename: 'deepseek-coder-6.7b-instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 4080000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/second-state/Deepseek-Coder-6.7B-Instruct-GGUF/resolve/main/deepseek-coder-6.7b-instruct-Q4_K_M.gguf',
  );

  static const WorkshopModelDescriptor reviewer =
      WorkshopModelDescriptor(
    id: 'starcoder2_3b',
    displayName: 'StarCoder2 3B',
    repository: 'second-state/StarCoder2-3B-GGUF',
    filename: 'starcoder2-3b-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 1850000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/second-state/StarCoder2-3B-GGUF/resolve/main/starcoder2-3b-Q4_K_M.gguf',
  );

  static const WorkshopModelDescriptor deepSeekV2Engineer =
      WorkshopModelDescriptor(
    id: 'deepseek_coder_v2_lite_instruct',
    displayName: 'DeepSeek Coder V2 Lite Instruct',
    repository: 'tensorblock/DeepSeek-Coder-V2-Lite-Instruct-GGUF',
    filename: 'DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    sizeBytes: 9653000000,
    source: AiModelSource.local,
    roles: <AppAiRole>{
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    },
    downloadUrl:
        'https://huggingface.co/tensorblock/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf',
    optional: true,
  );

  /// Models shown in the Workshop selector.
  ///
  /// Assistant-only models stay outside this list.
  static const List<WorkshopModelDescriptor> workshopModels =
      <WorkshopModelDescriptor>[
    workshopOrchestrator,
    architect,
    engineer,
    reviewer,
    deepSeekV2Engineer,
  ];

  /// Complete catalogue including Assistant-owned models.
  ///
  /// Used only where common infrastructure needs a complete physical model
  /// catalogue.
  static const List<WorkshopModelDescriptor> all =
      <WorkshopModelDescriptor>[
    assistantPhi35,
    ...workshopModels,
  ];

  static WorkshopModelDescriptor? findById(String id) {
    for (final model in all) {
      if (model.id == id) {
        return model;
      }
    }

    return null;
  }

  /// Models that the Workshop UI may expose for [role].
  ///
  /// The Assistant role is deliberately excluded.
  static List<WorkshopModelDescriptor> forRole(
    AppAiRole role,
  ) {
    if (role == AppAiRole.assistantOrchestrator) {
      return const <WorkshopModelDescriptor>[];
    }

    return workshopModels
        .where((model) => model.canServe(role))
        .toList(growable: false);
  }

  static bool isWorkshopModelId(String id) {
    return workshopModels.any(
      (model) => model.id == id,
    );
  }
}
