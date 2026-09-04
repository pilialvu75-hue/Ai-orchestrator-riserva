import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';

class WorkshopModelAssignment {
  const WorkshopModelAssignment({
    required this.role,
    required this.modelId,
  });

  final AppAiRole role;
  final String modelId;

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
        'Invalid WorkshopModelAssignment payload.',
      );
    }

    final role = AppAiRole.values.firstWhere(
      (candidate) => candidate.id == roleId,
      orElse: () => throw FormatException(
        'Unknown AI role: $roleId',
      ),
    );

    if (role == AppAiRole.assistantOrchestrator) {
      throw const FormatException(
        'Assistant role cannot be assigned inside Workshop.',
      );
    }

    return WorkshopModelAssignment(
      role: role,
      modelId: modelId,
    );
  }

  WorkshopModelAssignment copyWith({
    AppAiRole? role,
    String? modelId,
  }) {
    return WorkshopModelAssignment(
      role: role ?? this.role,
      modelId: modelId ?? this.modelId,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is WorkshopModelAssignment &&
            runtimeType == other.runtimeType &&
            role == other.role &&
            modelId == other.modelId;
  }

  @override
  int get hashCode => Object.hash(
        role,
        modelId,
      );

  @override
  String toString() {
    return 'WorkshopModelAssignment('
        'role: ${role.id}, '
        'modelId: $modelId'
        ')';
  }
}

class WorkshopModelAssignments {
  const WorkshopModelAssignments._();

  static const String _preferencesKey =
      'workshop.model.assignments.v1';

  static const List<WorkshopModelAssignment> defaults =
      <WorkshopModelAssignment>[
    WorkshopModelAssignment(
      role: AppAiRole.workshopOrchestrator,
      modelId: 'qwen2_5_3b_instruct',
    ),
    WorkshopModelAssignment(
      role: AppAiRole.architect,
      modelId: 'qwen2_5_coder_7b_instruct',
    ),
    WorkshopModelAssignment(
      role: AppAiRole.engineer,
      modelId: 'deepseek_coder_6_7b_instruct',
    ),
    WorkshopModelAssignment(
      role: AppAiRole.reviewer,
      modelId: 'starcoder2_3b',
    ),
  ];

  static const List<AppAiRole> workshopRoles =
      <AppAiRole>[
    AppAiRole.workshopOrchestrator,
    AppAiRole.architect,
    AppAiRole.engineer,
    AppAiRole.reviewer,
  ];

  static String? modelIdFor(
    AppAiRole role, {
    List<WorkshopModelAssignment> assignments = defaults,
  }) {
    for (final assignment in assignments) {
      if (assignment.role == role) {
        return assignment.modelId;
      }
    }

    return null;
  }

  /// Mantiene intenzionalmente la firma posizionale già usata
  /// dal resto del Cantiere:
  ///
  /// WorkshopModelAssignments.withAssignment(
  ///   assignments,
  ///   role,
  ///   modelId,
  /// );
  static List<WorkshopModelAssignment> withAssignment(
    List<WorkshopModelAssignment> assignments,
    AppAiRole role,
    String modelId,
  ) {
    if (role == AppAiRole.assistantOrchestrator) {
      throw ArgumentError.value(
        role,
        'role',
        'Assistant role cannot be assigned inside Workshop.',
      );
    }

    final normalizedModelId = modelId.trim();

    if (normalizedModelId.isEmpty) {
      throw ArgumentError.value(
        modelId,
        'modelId',
        'Workshop model id cannot be empty.',
      );
    }

    final updated = <WorkshopModelAssignment>[];
    var replaced = false;

    for (final assignment in assignments) {
      if (assignment.role == role) {
        updated.add(
          WorkshopModelAssignment(
            role: role,
            modelId: normalizedModelId,
          ),
        );
        replaced = true;
      } else {
        updated.add(assignment);
      }
    }

    if (!replaced) {
      updated.add(
        WorkshopModelAssignment(
          role: role,
          modelId: normalizedModelId,
        ),
      );
    }

    return List<WorkshopModelAssignment>.unmodifiable(
      updated,
    );
  }

  static List<WorkshopModelAssignment> withoutRole(
    List<WorkshopModelAssignment> assignments,
    AppAiRole role,
  ) {
    return List<WorkshopModelAssignment>.unmodifiable(
      assignments
          .where(
            (assignment) => assignment.role != role,
          )
          .toList(),
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
          'Assistant role cannot be used by Workshop.',
        );
        continue;
      }

      if (!workshopRoles.contains(assignment.role)) {
        errors.add(
          'Unsupported Workshop role: '
          '${assignment.role.id}.',
        );
      }

      if (!seenRoles.add(assignment.role)) {
        errors.add(
          'Duplicate assignment for role: '
          '${assignment.role.id}.',
        );
      }

      if (assignment.modelId.trim().isEmpty) {
        errors.add(
          'Empty model id for role: '
          '${assignment.role.id}.',
        );
        continue;
      }

      final model = WorkshopModelCatalogue.findById(
        assignment.modelId,
      );

      if (model == null) {
        errors.add(
          'Unknown Workshop model: '
          '${assignment.modelId}.',
        );
        continue;
      }

      if (!model.canServe(assignment.role)) {
        errors.add(
          'Model ${assignment.modelId} '
          'cannot serve role '
          '${assignment.role.id}.',
        );
      }
    }

    for (final role in workshopRoles) {
      if (!seenRoles.contains(role)) {
        errors.add(
          'Missing assignment for role: ${role.id}.',
        );
      }
    }

    return List<String>.unmodifiable(
      errors,
    );
  }

  static bool isValid(
    List<WorkshopModelAssignment> assignments,
  ) {
    return validate(assignments).isEmpty;
  }

  static Future<List<WorkshopModelAssignment>> load() async {
    final preferences =
        await SharedPreferences.getInstance();

    final raw = preferences.getString(
      _preferencesKey,
    );

    if (raw == null || raw.trim().isEmpty) {
      return defaults;
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        return defaults;
      }

      final loaded = <WorkshopModelAssignment>[];

      for (final item in decoded) {
        if (item is! Map) {
          return defaults;
        }

        loaded.add(
          WorkshopModelAssignment.fromJson(
            Map<String, dynamic>.from(item),
          ),
        );
      }

      if (!isValid(loaded)) {
        return defaults;
      }

      return List<WorkshopModelAssignment>.unmodifiable(
        loaded,
      );
    } catch (_) {
      return defaults;
    }
  }

  static Future<void> save(
    List<WorkshopModelAssignment> assignments,
  ) async {
    final errors = validate(assignments);

    if (errors.isNotEmpty) {
      throw StateError(
        'Cannot save invalid Workshop model assignments: '
        '${errors.join(' | ')}',
      );
    }

    final preferences =
        await SharedPreferences.getInstance();

    final payload = jsonEncode(
      assignments
          .map(
            (assignment) => assignment.toJson(),
          )
          .toList(),
    );

    await preferences.setString(
      _preferencesKey,
      payload,
    );
  }

  static Future<void> reset() async {
    final preferences =
        await SharedPreferences.getInstance();

    await preferences.remove(
      _preferencesKey,
    );
  }
}
