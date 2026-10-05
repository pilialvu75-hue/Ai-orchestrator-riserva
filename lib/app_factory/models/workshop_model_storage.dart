import 'dart:io';

import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';

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

  /// Cloud descriptors are runtime-ready without a local GGUF. Authentication
  /// and provider health are checked later by CloudRuntimeProvider.
  bool get isReady => model.isCloud || (exists && (actualBytes ?? 0) > 0);

  bool get needsDownload => !model.isCloud && !exists;

  bool get hasPersistentCopy {
    if (model.isCloud || publicPath.isEmpty) return false;
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
  /// Cloud models deliberately bypass local filesystem resolution. Their
  /// availability depends on credentials/network and is enforced by the Cloud
  /// runtime, not by the GGUF download store.
  Future<WorkshopModelStorageState> inspect(
    WorkshopModelDescriptor model,
  ) async {
    if (model.isCloud) {
      return WorkshopModelStorageState(
        model: model,
        path: '',
        publicPath: '',
        exists: false,
        isPublic: false,
      );
    }

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
  /// Cloud models have no local path.
  String publicPathFor(WorkshopModelDescriptor model) {
    if (model.isCloud) return '';
    return _pathResolver.publicFileByName(model.filename).path;
  }

  /// Returns the application's private model path.
  ///
  /// Cloud models have no local path.
  Future<String> privatePathFor(
    WorkshopModelDescriptor model,
  ) async {
    if (model.isCloud) return '';

    final file = await _pathResolver.privateFileByName(
      model.filename,
    );

    return file.path;
  }

  /// Checks whether a persistent exported copy already exists.
  ///
  /// Cloud models are never exported to the GGUF model folder.
  Future<bool> hasPersistentCopy(
    WorkshopModelDescriptor model,
  ) async {
    if (model.isCloud) return false;

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
      if (model.isCloud) continue;
      final state = await inspect(model);

      if (state.isReady) {
        result.add(model);
      }
    }

    return List.unmodifiable(result);
  }

  /// Finds local models that are not currently available.
  Future<List<WorkshopModelDescriptor>> missingModels() async {
    final result = <WorkshopModelDescriptor>[];

    for (final model in WorkshopModelCatalogue.all) {
      if (model.isCloud) continue;
      final state = await inspect(model);

      if (!state.isReady) {
        result.add(model);
      }
    }

    return List.unmodifiable(result);
  }
}
