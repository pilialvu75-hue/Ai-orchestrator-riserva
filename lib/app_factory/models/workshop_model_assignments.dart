import 'package:flutter/foundation.dart';

import 'workshop_model_roles.dart';

/// Persistent assignment of a model to a logical AI role.
///
/// Workshop assignments are intentionally independent from the Assistant
/// model selection. The Workshop owns its four technical roles:
///
///   Orchestrator -> Qwen2.5 3B
///   Architect    -> Qwen2.5-Coder 7B
///   Engineer     -> DeepSeek Coder 6.7B
///   Reviewer     -> StarCoder2 3B
///
/// Model downloading, verification, storage and runtime loading remain
/// responsibilities of the existing shared model-management infrastructure.
///
/// IMPORTANT:
/// The shared infrastructure is allowed to share the physical GGUF files,
/// but Workshop selection/configuration must never inherit the Assistant's
/// selected model.
@immutable
class WorkshopModelAssignment {
  const WorkshopModelAssignment({
    required this.role,
    required this.modelId,
  });

  final AppAiRole role;
  final String modelId;

  WorkshopModelAssignment copyWith({
    AppAiRole? role,
    String? modelId,
  }) {
    return WorkshopModelAssignment(
      role: role ?? this.role,
      modelId: modelId ?? this.modelId,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'role': role.id,
      'modelId': modelId,
    };
  }

  factory WorkshopModelAssignment.fromJson(
    Map<String, dynamic> json,
  ) {
    final roleId = json['role'] as String?;
    final modelId = json['modelId'] as String?;

    if (roleId == null || modelId == null) {
      throw const FormatException(
        'Invalid WorkshopModelAssignment: missing role or modelId.',
      );
    }

    final role = _roleFromId(roleId);
    if (role == null) {
      throw FormatException(
        'Unknown Workshop AI role: $roleId',
      );
    }

    // The Assistant role is deliberately not accepted as a Workshop
    // assignment. The Assistant and Workshop have independent configuration.
    if (role == AppAiRole.assistantOrchestrator) {
      throw const FormatException(
        'Assistant role cannot be assigned through Workshop configuration.',
      );
    }

    return WorkshopModelAssignment(
      role: role,
      modelId: modelId,
    );
  }

  static AppAiRole? _roleFromId(String id) {
    for (final role in AppAiRole.values) {
      if (role.id == id) {
        return role;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    return other is WorkshopModelAssignment &&
        other.role == role &&
        other.modelId == modelId;
  }

  @override
  int get hashCode => Object.hash(role, modelId);

  @override
  String toString() {
    return 'WorkshopModelAssignment('
        'role=${role.id}, '
        'modelId=$modelId'
        ')';
  }
}

/// Default model-role configuration for the Workshop.
///
/// The Assistant is intentionally NOT part of this list.
///
/// The two systems share model download/storage infrastructure, but their
/// model selection is independent:
///
/// Assistant:
///   managed by the Assistant model-selection system.
///
/// Workshop:
///   Orchestrator -> Qwen2.5 3B
///   Architect    -> Qwen2.5-Coder 7B
///   Engineer     -> DeepSeek Coder 6.7B
///   Reviewer     -> StarCoder2 3B
///
/// This separation is important because changing the Assistant's selected
/// model must never silently change the model used by the Workshop.
abstract final class WorkshopModelAssignments {
  static const WorkshopModelAssignment orchestrator =
      WorkshopModelAssignment(
    role: AppAiRole.workshopOrchestrator,
    modelId: 'qwen2_5_3b_instruct',
  );

  static const WorkshopModelAssignment architect =
      WorkshopModelAssignment(
    role: AppAiRole.architect,
    modelId: 'qwen2_5_coder_7b_instruct',
  );

  static const WorkshopModelAssignment engineer =
      WorkshopModelAssignment(
    role: AppAiRole.engineer,
    modelId: 'deepseek_coder_6_7b_instruct',
  );

  static const WorkshopModelAssignment reviewer =
      WorkshopModelAssignment(
    role: AppAiRole.reviewer,
    modelId: 'starcoder2_3b',
  );

  /// Default assignments belonging exclusively to the Workshop.
  ///
  /// Do NOT add AppAiRole.assistantOrchestrator here.
  static const List<WorkshopModelAssignment> defaults =
      <WorkshopModelAssignment>[
    orchestrator,
    architect,
    engineer,
    reviewer,
  ];

  /// Returns the configured model ID for [role].
  ///
  /// Returns null if no assignment exists. This makes the configuration
  /// forward-compatible with roles that may be added later.
  static String? modelIdFor(
    AppAiRole role, {
    List<WorkshopModelAssignment> assignments = defaults,
  }) {
    // Never resolve the Assistant through the Workshop configuration.
    if (role == AppAiRole.assistantOrchestrator) {
      return null;
    }

    for (final assignment in assignments) {
      if (assignment.role == role) {
        return assignment.modelId;
      }
    }

    return null;
  }

  /// Replaces or creates the assignment for [role].
  ///
  /// The Assistant role cannot be configured through the Workshop.
  ///
  /// The returned list is immutable from the caller's perspective.
  static List<WorkshopModelAssignment> withAssignment(
    List<WorkshopModelAssignment> assignments,
    AppAiRole role,
    String modelId,
  ) {
    if (role == AppAiRole.assistantOrchestrator) {
      return List.unmodifiable(assignments);
    }

    final result = <WorkshopModelAssignment>[];
    var replaced = false;

    for (final assignment in assignments) {
      if (assignment.role == role) {
        result.add(
          WorkshopModelAssignment(
            role: role,
            modelId: modelId,
          ),
        );
        replaced = true;
      } else {
        result.add(assignment);
      }
    }

    if (!replaced) {
      result.add(
        WorkshopModelAssignment(
          role: role,
          modelId: modelId,
        ),
      );
    }

    return List.unmodifiable(result);
  }

  /// Removes an assignment for [role].
  ///
  /// This does not delete the model from storage. It only removes the role
  /// association.
  static List<WorkshopModelAssignment> withoutRole(
    List<WorkshopModelAssignment> assignments,
    AppAiRole role,
  ) {
    return List.unmodifiable(
      assignments.where(
        (assignment) => assignment.role != role,
      ),
    );
  }

  /// Validates assignments against the current Workshop model catalogue.
  ///
  /// This method does not touch the filesystem and does not download anything.
  /// It verifies:
  ///   - no duplicate roles exist;
  ///   - the Assistant is not assigned to the Workshop;
  ///   - every assigned model exists;
  ///   - every assigned model supports its selected role.
  static List<String> validate(
    List<WorkshopModelAssignment> assignments,
  ) {
    final errors = <String>[];
    final seenRoles = <AppAiRole>{};

    for (final assignment in assignments) {
      if (assignment.role == AppAiRole.assistantOrchestrator) {
        errors.add(
          'Assistant role cannot be assigned through Workshop '
          'model configuration.',
        );
        continue;
      }

      if (!seenRoles.add(assignment.role)) {
        errors.add(
          'Duplicate model assignment for role '
          '${assignment.role.id}.',
        );
      }

      final model = WorkshopModelCatalogue.findById(
        assignment.modelId,
      );

      if (model == null) {
        errors.add(
          'Model "${assignment.modelId}" is not present '
          'in the Workshop model catalogue.',
        );
        continue;
      }

      if (!model.canServe(assignment.role)) {
        errors.add(
          'Model "${assignment.modelId}" cannot serve role '
          '"${assignment.role.id}".',
        );
      }
    }

    // The four Workshop roles must have an assignment in the default
    // configuration. This prevents a silently incomplete Workshop.
    const requiredRoles = <AppAiRole>{
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    };

    for (final role in requiredRoles) {
      if (!seenRoles.contains(role)) {
        errors.add(
          'Missing Workshop model assignment for role '
          '"${role.id}".',
        );
      }
    }

    return List.unmodifiable(errors);
  }

  static bool isValid(
    List<WorkshopModelAssignment> assignments,
  ) {
    return validate(assignments).isEmpty;
  }
}
