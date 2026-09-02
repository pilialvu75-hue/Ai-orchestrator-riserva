import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workshop_model_roles.dart';

/// Persistent assignment of a model to a logical Workshop AI role.
///
/// The Assistant has a completely separate model-selection mechanism.
/// Workshop assignments are stored under their own preference namespace.
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

/// Workshop model configuration.
///
/// This class is intentionally independent from the Assistant model
/// selection. Both systems may share the physical GGUF and downloader,
/// but not the preference that identifies the active model.
abstract final class WorkshopModelAssignments {
  static const String _prefsKey =
      'workshop.model.assignments.v1';

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

  static const List<WorkshopModelAssignment> defaults =
      <WorkshopModelAssignment>[
    orchestrator,
    architect,
    engineer,
    reviewer,
  ];

  /// Loads the persisted Workshop assignments.
  ///
  /// Missing/corrupt configuration falls back safely to [defaults].
  static Future<List<WorkshopModelAssignment>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);

    if (raw == null || raw.trim().isEmpty) {
      return defaults;
    }

    try {
      final decoded = Uri.decodeComponent(raw);

      final entries = decoded
          .split('|')
          .where((entry) => entry.trim().isNotEmpty)
          .map((entry) {
        final separator = entry.indexOf('=');

        if (separator <= 0 ||
            separator >= entry.length - 1) {
          throw const FormatException(
            'Invalid Workshop assignment entry.',
          );
        }

        return WorkshopModelAssignment.fromJson(
          <String, dynamic>{
            'role': entry.substring(0, separator),
            'modelId': entry.substring(separator + 1),
          },
        );
      }).toList(growable: false);

      final errors = validate(entries);

      if (errors.isNotEmpty) {
        return defaults;
      }

      return List.unmodifiable(entries);
    } catch (_) {
      return defaults;
    }
  }

  /// Persists the complete Workshop configuration.
  ///
  /// The Assistant preference is never touched.
  static Future<void> save(
    List<WorkshopModelAssignment> assignments,
  ) async {
    if (!isValid(assignments)) {
      throw ArgumentError(
        'Invalid Workshop model assignments: '
        '${validate(assignments).join('; ')}',
      );
    }

    final prefs = await SharedPreferences.getInstance();

    final encoded = Uri.encodeComponent(
      assignments
          .map(
            (assignment) =>
                '${assignment.role.id}=${assignment.modelId}',
          )
          .join('|'),
    );

    await prefs.setString(
      _prefsKey,
      encoded,
    );
  }

  static String? modelIdFor(
    AppAiRole role, {
    List<WorkshopModelAssignment> assignments = defaults,
  }) {
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

  static List<WorkshopModelAssignment> withAssignment(
    List<WorkshopModelAssignment> assignments,
    AppAiRole role,
    String modelId,
  ) {
    if (role == AppAiRole.assistantOrchestrator) {
      return List.unmodifiable(assignments);
    }

    if (WorkshopModelCatalogue.findById(modelId) == null) {
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

  static List<String> validate(
    List<WorkshopModelAssignment> assignments,
  ) {
    final errors = <String>[];
    final seenRoles = <AppAiRole>{};

    for (final assignment in assignments) {
      if (assignment.role ==
          AppAiRole.assistantOrchestrator) {
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

      if (!model.isWorkshopModel) {
        errors.add(
          'Model "${assignment.modelId}" is not a Workshop model.',
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
