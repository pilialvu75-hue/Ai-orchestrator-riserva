import 'dart:io';

import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';

import 'workshop_model_roles.dart';

/// Describes the physical state of a Workshop model.
///
/// This class does not download, move or delete anything.
class WorkshopModelStorageState {
  const WorkshopModelStorageState({
    required this.model,
    required this.path,
    required this.publicPath,
    required this.exists,
    required this.isPublic,
    this.actualBytes,
  });

  final WorkshopModelDescriptor model;

  /// Path currently selected by the existing runtime path resolver.
  final String path;

  /// Persistent public/export path.
  final String publicPath;

  final bool exists;
  final bool isPublic;
  final int? actualBytes;

  bool get isReady => exists && (actualBytes ?? 0) > 0;

  bool get needsDownload => !exists;

  bool get hasPersistentCopy {
    return File(publicPath).existsSync();
  }
}

/// Read-only bridge between the Workshop model catalogue and the existing
/// model storage infrastructure.
///
/// IMPORTANT:
/// - This class does NOT implement a second downloader.
/// - This class does NOT move or delete model files.
/// - This class does NOT change the existing update system.
/// - This class does NOT change the local runtime.
///
/// It uses the same RuntimeModelPathResolver already used by the application.
class WorkshopModelStorage {
  const WorkshopModelStorage({
    RuntimeModelPathResolver pathResolver =
        const RuntimeModelPathResolver(),
  }) : _pathResolver = pathResolver;

  final RuntimeModelPathResolver _pathResolver;

  /// Inspect the physical storage state of one Workshop model.
  ///
  /// The resolver preserves the application's existing priority:
  /// private app storage first, persistent public storage second.
  Future<WorkshopModelStorageState> inspect(
    WorkshopModelDescriptor model,
  ) async {
    final resolution = await _pathResolver.resolveForRead(
      fileName: model.filename,
    );

    int? actualBytes;

    if (resolution.exists) {
      try {
        actualBytes = await resolution.file.length();
      } catch (_) {
        actualBytes = null;
      }
    }

    return WorkshopModelStorageState(
      model: model,
      path: resolution.file.path,
      publicPath: resolution.publicFile.path,
      exists: resolution.exists && (actualBytes ?? 0) > 0,
      isPublic:
          resolution.location == RuntimeModelStorageLocation.publicDownload,
      actualBytes: actualBytes,
    );
  }

  /// Inspect every model in the Workshop catalogue.
  Future<List<WorkshopModelStorageState>> inspectAll() async {
    final result = <WorkshopModelStorageState>[];

    for (final model in WorkshopModelCatalogue.all) {
      result.add(await inspect(model));
    }

    return List.unmodifiable(result);
  }

  /// Returns the model currently available for [role].
  ///
  /// This only reads the catalogue. It does not load the model into memory.
  Future<WorkshopModelStorageState?> inspectRole(
    AppAiRole role,
  ) async {
    final candidates = WorkshopModelCatalogue.forRole(role);

    if (candidates.isEmpty) {
      return null;
    }

    // Prefer the first compatible model in catalogue order.
    // Actual role assignment will be handled by WorkshopModelAssignments.
    return inspect(candidates.first);
  }

  /// Returns the persistent public path used by the existing application.
  ///
  /// No directory is created here. This is intentionally read-only.
  String publicPathFor(WorkshopModelDescriptor model) {
    return _pathResolver.publicFileByName(model.filename).path;
  }

  /// Returns the application's private model path.
  ///
  /// No directory or file is created here.
  Future<String> privatePathFor(
    WorkshopModelDescriptor model,
  ) async {
    final file = await _pathResolver.privateFileByName(
      model.filename,
    );

    return file.path;
  }

  /// Checks whether a persistent exported copy already exists.
  ///
  /// The public folder survives application uninstall, so this allows the
  /// Workshop to recognise a model that was exported previously.
  Future<bool> hasPersistentCopy(
    WorkshopModelDescriptor model,
  ) async {
    final file = _pathResolver.publicFileByName(
      model.filename,
    );

    try {
      if (!await file.exists()) {
        return false;
      }

      return await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Finds models that are already available locally.
  Future<List<WorkshopModelDescriptor>> installedModels() async {
    final result = <WorkshopModelDescriptor>[];

    for (final model in WorkshopModelCatalogue.all) {
      final state = await inspect(model);

      if (state.isReady) {
        result.add(model);
      }
    }

    return List.unmodifiable(result);
  }

  /// Finds models that are not currently available.
  Future<List<WorkshopModelDescriptor>> missingModels() async {
    final result = <WorkshopModelDescriptor>[];

    for (final model in WorkshopModelCatalogue.all) {
      final state = await inspect(model);

      if (!state.isReady) {
        result.add(model);
      }
    }

    return List.unmodifiable(result);
  }
}
