import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_storage.dart';

/// Result of resolving a Workshop role to a concrete local model.
@immutable
class WorkshopModelResolution {
  const WorkshopModelResolution({
    required this.role,
    required this.model,
    required this.storage,
  });

  final AppAiRole role;
  final WorkshopModelDescriptor model;
  final WorkshopModelStorageState storage;

  bool get isReady => storage.isReady;

  bool get needsDownload => storage.needsDownload;

  bool get hasPersistentCopy => storage.hasPersistentCopy;

  String get modelPath => storage.path;
}

/// Resolves Workshop roles into concrete models and their local storage state.
///
/// This class is deliberately read-only.
///
/// It does not:
/// - download models;
/// - delete models;
/// - move models;
/// - load models into llama.cpp;
/// - change the Assistant runtime;
/// - change the existing update mechanism.
///
/// Downloading remains the responsibility of the existing model-management
/// infrastructure.
class WorkshopModelResolver {
  const WorkshopModelResolver({
    this.storage = const WorkshopModelStorage(),
  });

  final WorkshopModelStorage storage;

  /// Resolve one role using the supplied assignments.
  ///
  /// If [assignments] is omitted, the current Workshop defaults are used.
  Future<WorkshopModelResolution?> resolveRole(
    AppAiRole role, {
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) async {
    final modelId = WorkshopModelAssignments.modelIdFor(
      role,
      assignments: assignments,
    );

    if (modelId == null) {
      return null;
    }

    final model = WorkshopModelCatalogue.findById(modelId);

    if (model == null) {
      return null;
    }

    if (!model.canServe(role)) {
      return null;
    }

    final state = await storage.inspect(model);

    return WorkshopModelResolution(
      role: role,
      model: model,
      storage: state,
    );
  }

  /// Resolve all configured Workshop roles.
  Future<List<WorkshopModelResolution>> resolveAll({
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) async {
    final result = <WorkshopModelResolution>[];

    for (final assignment in assignments) {
      final resolution = await resolveRole(
        assignment.role,
        assignments: assignments,
      );

      if (resolution != null) {
        result.add(resolution);
      }
    }

    return List.unmodifiable(result);
  }

  /// Returns only roles whose assigned model is currently available locally.
  Future<List<WorkshopModelResolution>> resolveReady({
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) async {
    final resolutions = await resolveAll(
      assignments: assignments,
    );

    return List.unmodifiable(
      resolutions.where(
        (resolution) => resolution.isReady,
      ),
    );
  }

  /// Returns roles whose assigned model is missing.
  Future<List<WorkshopModelResolution>> resolveMissing({
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) async {
    final resolutions = await resolveAll(
      assignments: assignments,
    );

    return List.unmodifiable(
      resolutions.where(
        (resolution) => resolution.needsDownload,
      ),
    );
  }

  /// Checks whether every configured role has a valid catalogue assignment.
  ///
  /// This does not require models to be downloaded.
  bool validateAssignments({
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) {
    return WorkshopModelAssignments.isValid(
      assignments,
    );
  }

  /// Returns a human-readable list of configuration errors.
  List<String> validateAssignmentErrors({
    List<WorkshopModelAssignment> assignments =
        WorkshopModelAssignments.defaults,
  }) {
    return WorkshopModelAssignments.validate(
      assignments,
    );
  }
}
