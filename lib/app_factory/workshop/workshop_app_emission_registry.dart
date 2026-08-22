import 'workshop_app_emission_package.dart';

/// Registro in-memory delle applicazioni emesse dal Cantiere.
///
/// Il Registry non esegue build, non installa APK e non pubblica
/// artifact. Conserva solamente i pacchetti di emissione già prodotti.
///
/// In futuro potrà essere sostituito internamente da SQLite/Isar
/// senza modificare il contratto pubblico.
final class WorkshopAppEmissionRegistry {
  WorkshopAppEmissionRegistry({
    List<WorkshopAppEmissionPackage> initialPackages =
        const <WorkshopAppEmissionPackage>[],
  }) : _packages = <WorkshopAppEmissionPackage>[
          ...initialPackages,
        ];

  final List<WorkshopAppEmissionPackage> _packages;

  List<WorkshopAppEmissionPackage> get packages =>
      List<WorkshopAppEmissionPackage>.unmodifiable(
        _packages,
      );

  int get length => _packages.length;

  bool get isEmpty => _packages.isEmpty;

  bool get isNotEmpty => _packages.isNotEmpty;

  void register(
    WorkshopAppEmissionPackage package,
  ) {
    _packages.add(package);
  }

  void registerAll(
    Iterable<WorkshopAppEmissionPackage> packages,
  ) {
    _packages.addAll(packages);
  }

  WorkshopAppEmissionPackage? findById(
    String id,
  ) {
    for (final package in _packages) {
      if (package.id == id) {
        return package;
      }
    }

    return null;
  }

  WorkshopAppEmissionPackage? findByRequestId(
    String requestId,
  ) {
    for (final package in _packages) {
      if (package.requestId == requestId) {
        return package;
      }
    }

    return null;
  }

  List<WorkshopAppEmissionPackage> recent({
    int limit = 20,
  }) {
    if (limit <= 0 || _packages.isEmpty) {
      return const <WorkshopAppEmissionPackage>[];
    }

    final sorted =
        List<WorkshopAppEmissionPackage>.from(
      _packages,
    )..sort(
        (a, b) => b.createdAt.compareTo(
          a.createdAt,
        ),
      );

    final count = limit < sorted.length
        ? limit
        : sorted.length;

    return List<WorkshopAppEmissionPackage>.unmodifiable(
      sorted.take(count),
    );
  }

  bool removeById(String id) {
    final index = _packages.indexWhere(
      (package) => package.id == id,
    );

    if (index < 0) {
      return false;
    }

    _packages.removeAt(index);
    return true;
  }

  void clear() {
    _packages.clear();
  }

  int get readyCount {
    return _packages
        .where(
          (package) => package.isReady,
        )
        .length;
  }

  Map<String, int> packagesByTarget() {
    final result = <String, int>{};

    for (final package in _packages) {
      final target = package.target.trim().isEmpty
          ? 'unknown'
          : package.target;

      result[target] =
          (result[target] ?? 0) + 1;
    }

    return Map<String, int>.unmodifiable(
      result,
    );
  }

  Map<String, dynamic> diagnostics() {
    return <String, dynamic>{
      'length': _packages.length,
      'isEmpty': _packages.isEmpty,
      'readyCount': readyCount,
      'packagesByTarget':
          packagesByTarget(),
    };
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'packages': _packages
          .map(
            (package) => package.toJson(),
          )
          .toList(
            growable: false,
          ),
    };
  }

  factory WorkshopAppEmissionRegistry.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawPackages =
        json['packages'];

    if (rawPackages is! List) {
      return WorkshopAppEmissionRegistry();
    }

    final packages =
        <WorkshopAppEmissionPackage>[];

    for (final value in rawPackages) {
      if (value is Map) {
        packages.add(
          WorkshopAppEmissionPackage.fromJson(
            Map<String, dynamic>.from(
              value,
            ),
          ),
        );
      }
    }

    return WorkshopAppEmissionRegistry(
      initialPackages: packages,
    );
  }
}
