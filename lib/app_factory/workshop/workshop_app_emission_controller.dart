import 'workshop_app_emission_package.dart';
import 'workshop_app_emission_registry.dart';

/// Stato osservabile dell'emissione del Cantiere.
///
/// È volutamente indipendente dalla UI: la schermata del Cantiere
/// potrà ascoltare questo stato senza conoscere il Registry interno.
final class WorkshopAppEmissionState {
  const WorkshopAppEmissionState({
    required this.totalPackages,
    required this.readyPackages,
    this.latestPackage,
  });

  final int totalPackages;
  final int readyPackages;
  final WorkshopAppEmissionPackage? latestPackage;

  bool get hasEmittedApp =>
      readyPackages > 0;

  bool get isEmpty =>
      totalPackages == 0;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'totalPackages': totalPackages,
      'readyPackages': readyPackages,
      'hasEmittedApp': hasEmittedApp,
      'latestPackage':
          latestPackage?.toJson(),
    };
  }
}

/// Controller tra Registry e futura UI del Cantiere.
///
/// Non esegue build e non emette direttamente artifact.
/// Legge il Registry e mantiene una fotografia coerente dello
/// stato di emissione attualmente disponibile.
final class WorkshopAppEmissionController {
  WorkshopAppEmissionController({
    WorkshopAppEmissionRegistry? registry,
  }) : _registry =
            registry ??
                WorkshopAppEmissionRegistry();

  final WorkshopAppEmissionRegistry _registry;

  WorkshopAppEmissionRegistry get registry =>
      _registry;

  WorkshopAppEmissionState get state {
    final packages =
        _registry.recent(
      limit: _registry.length,
    );

    WorkshopAppEmissionPackage? latest;

    if (packages.isNotEmpty) {
      latest = packages.first;
    }

    return WorkshopAppEmissionState(
      totalPackages:
          _registry.length,
      readyPackages:
          _registry.readyCount,
      latestPackage: latest,
    );
  }

  WorkshopAppEmissionPackage? get latest =>
      state.latestPackage;

  bool get hasEmittedApp =>
      state.hasEmittedApp;

  void register(
    WorkshopAppEmissionPackage package,
  ) {
    if (!package.isReady) {
      return;
    }

    _registry.register(package);
  }

  void registerAll(
    Iterable<WorkshopAppEmissionPackage> packages,
  ) {
    for (final package in packages) {
      register(package);
    }
  }

  WorkshopAppEmissionPackage? findById(
    String id,
  ) {
    return _registry.findById(id);
  }

  WorkshopAppEmissionPackage? findByRequestId(
    String requestId,
  ) {
    return _registry.findByRequestId(
      requestId,
    );
  }

  List<WorkshopAppEmissionPackage> recent({
    int limit = 20,
  }) {
    return _registry.recent(
      limit: limit,
    );
  }

  bool removeById(String id) {
    return _registry.removeById(id);
  }

  void clear() {
    _registry.clear();
  }

  Map<String, dynamic> diagnostics() {
    final currentState = state;

    return <String, dynamic>{
      'controller':
          'workshop-app-emission',
      'totalPackages':
          currentState.totalPackages,
      'readyPackages':
          currentState.readyPackages,
      'hasEmittedApp':
          currentState.hasEmittedApp,
      'latestPackageId':
          currentState.latestPackage?.id,
      'latestRequestId':
          currentState.latestPackage?.requestId,
      'latestArtifactPath':
          currentState
              .latestPackage
              ?.artifactPath,
      'registry':
          _registry.diagnostics(),
    };
  }
}
