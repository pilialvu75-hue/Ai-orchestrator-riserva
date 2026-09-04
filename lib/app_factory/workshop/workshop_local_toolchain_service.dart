import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_detector.dart';

/// Servizio unificato per la toolchain locale.
///
/// Il Service rappresenta il punto di accesso del Workshop alla
/// toolchain locale.
///
/// Architettura:
///
///   Detector
///       ↓
///   LocalToolchainService
///       ↓
///   Local Executor / Build Lab
///
/// Il Service:
///
/// - non installa nulla;
/// - non scarica dipendenze;
/// - non esegue build;
/// - non modifica il repository;
/// - non usa provider AI;
/// - non decide autonomamente di usare GitHub;
/// - espone lo stato della toolchain in modo semplice e prevedibile.
///
/// La decisione LOCAL / REMOTE / HYBRID rimane responsabilità
/// dei livelli superiori del Workshop.
final class WorkshopLocalToolchainService {
  WorkshopLocalToolchainService({
    WorkshopLocalToolchainDetector? detector,
  }) : _detector =
            detector ?? WorkshopLocalToolchainDetector();

  final WorkshopLocalToolchainDetector _detector;

  WorkshopLocalToolchainReport? _lastReport;

  DateTime? _lastInspectionAt;

  /// Ultimo report disponibile.
  ///
  /// È null prima della prima ispezione.
  WorkshopLocalToolchainReport? get lastReport =>
      _lastReport;

  /// Momento dell'ultima ispezione.
  DateTime? get lastInspectionAt =>
      _lastInspectionAt;

  /// Indica se il Service possiede già un report.
  bool get hasReport =>
      _lastReport != null;

  /// Esegue una nuova ispezione completa.
  ///
  /// Non utilizza cache: questa operazione interroga nuovamente
  /// la toolchain.
  Future<WorkshopLocalToolchainReport> inspect() async {
    final report = await _detector.inspectAll();

    _lastReport = report;
    _lastInspectionAt =
        DateTime.now().toUtc();

    return report;
  }

  /// Restituisce il report esistente oppure esegue la prima
  /// ispezione.
  Future<WorkshopLocalToolchainReport>
      ensureInspected() async {
    final existing = _lastReport;

    if (existing != null) {
      return existing;
    }

    return inspect();
  }

  /// Restituisce le informazioni per un target.
  Future<WorkshopToolchainInfo> inspectTarget(
    WorkshopBuildTarget target,
  ) async {
    final info =
        await _detector.inspectTarget(target);

    _updateTargetInCachedReport(info);

    return info;
  }

  /// Restituisce le informazioni già disponibili per un target.
  WorkshopToolchainInfo? cachedTargetInfo(
    WorkshopBuildTarget target,
  ) {
    return _lastReport?.infoFor(target);
  }

  /// Verifica se il target può essere costruito localmente
  /// secondo l'ultimo report.
  ///
  /// Se non esiste ancora un report, restituisce false:
  /// il Service non presume mai che una toolchain sia disponibile.
  bool canBuildLocally(
    WorkshopBuildTarget target,
  ) {
    final info =
        _lastReport?.infoFor(target);

    return info?.isAvailable ?? false;
  }

  /// Verifica se il target può essere costruito offline
  /// secondo l'ultimo report.
  bool canBuildOffline(
    WorkshopBuildTarget target,
  ) {
    final info =
        _lastReport?.infoFor(target);

    return info?.canBuildOffline ?? false;
  }

  /// Verifica se almeno un target può essere costruito localmente.
  bool get hasLocalBuildCapability {
    final report = _lastReport;

    if (report == null) {
      return false;
    }

    return report.targets.values.any(
      (info) => info.isAvailable,
    );
  }

  /// Verifica se almeno un target può essere costruito offline.
  bool get hasOfflineBuildCapability {
    final report = _lastReport;

    if (report == null) {
      return false;
    }

    return report.targets.values.any(
      (info) => info.canBuildOffline,
    );
  }

  /// Restituisce tutti i target disponibili localmente.
  List<WorkshopBuildTarget> get localTargets {
    final report = _lastReport;

    if (report == null) {
      return const <WorkshopBuildTarget>[];
    }

    return List<WorkshopBuildTarget>.unmodifiable(
      report.targets.entries
          .where(
            (entry) => entry.value.isAvailable,
          )
          .map(
            (entry) => entry.key,
          ),
    );
  }

  /// Restituisce tutti i target che risultano utilizzabili offline.
  List<WorkshopBuildTarget> get offlineTargets {
    final report = _lastReport;

    if (report == null) {
      return const <WorkshopBuildTarget>[];
    }

    return List<WorkshopBuildTarget>.unmodifiable(
      report.targets.entries
          .where(
            (entry) => entry.value.canBuildOffline,
          )
          .map(
            (entry) => entry.key,
          ),
    );
  }

  /// Restituisce una modalità locale appropriata per il target.
  ///
  /// Non decide un fallback remoto.
  ///
  /// Se il target è disponibile offline:
  ///
  ///     offlineLocal
  ///
  /// Se è disponibile ma non può essere classificato come offline:
  ///
  ///     local
  ///
  /// Altrimenti:
  ///
  ///     remote
  ///
  /// Il valore `remote` non significa che il Service eseguirà
  /// realmente una build remota. Significa solamente che la
  /// toolchain locale non è sufficiente.
  WorkshopBuildExecutionMode recommendedExecutionMode(
    WorkshopBuildTarget target,
  ) {
    final info =
        _lastReport?.infoFor(target);

    if (info == null) {
      return WorkshopBuildExecutionMode.remote;
    }

    if (info.canBuildOffline) {
      return WorkshopBuildExecutionMode.offlineLocal;
    }

    if (info.isAvailable) {
      return WorkshopBuildExecutionMode.local;
    }

    return WorkshopBuildExecutionMode.remote;
  }

  /// Restituisce una decisione diagnostica semplice per la UI.
  ///
  /// Questa funzione non esegue nessuna azione.
  WorkshopLocalToolchainDecision decisionFor(
    WorkshopBuildTarget target,
  ) {
    final report = _lastReport;

    if (report == null) {
      return WorkshopLocalToolchainDecision(
        target: target,
        available: false,
        offline: false,
        mode:
            WorkshopBuildExecutionMode.remote,
        reason:
            'Local toolchain has not been inspected yet.',
        missingComponents:
            const <String>[],
      );
    }

    final info =
        report.infoFor(target);

    if (info == null) {
      return WorkshopLocalToolchainDecision(
        target: target,
        available: false,
        offline: false,
        mode:
            WorkshopBuildExecutionMode.remote,
        reason:
            'No toolchain information is available for this target.',
        missingComponents:
            const <String>[],
      );
    }

    if (info.canBuildOffline) {
      return WorkshopLocalToolchainDecision(
        target: target,
        available: true,
        offline: true,
        mode:
            WorkshopBuildExecutionMode.offlineLocal,
        reason:
            'Target is available through the local offline toolchain.',
        missingComponents:
            List<String>.unmodifiable(
          info.missingComponents,
        ),
      );
    }

    if (info.isAvailable) {
      return WorkshopLocalToolchainDecision(
        target: target,
        available: true,
        offline: false,
        mode:
            WorkshopBuildExecutionMode.local,
        reason:
            'Target is available through the local toolchain.',
        missingComponents:
            List<String>.unmodifiable(
          info.missingComponents,
        ),
      );
    }

    return WorkshopLocalToolchainDecision(
      target: target,
      available: false,
      offline: false,
      mode:
          WorkshopBuildExecutionMode.remote,
      reason:
          info.message ??
          'Local toolchain is unavailable for this target.',
      missingComponents:
          List<String>.unmodifiable(
        info.missingComponents,
      ),
    );
  }

  /// Produce un riepilogo diagnostico utile alla UI e ai log.
  Map<String, dynamic> diagnostics() {
    final report = _lastReport;

    if (report == null) {
      return <String, dynamic>{
        'inspected': false,
        'localBuildCapability': false,
        'offlineBuildCapability': false,
        'localTargets':
            const <String>[],
        'offlineTargets':
            const <String>[],
      };
    }

    return <String, dynamic>{
      'inspected': true,
      'checkedAt':
          report.checkedAt
              .toUtc()
              .toIso8601String(),
      'flutterAvailable':
          report.flutterAvailable,
      'dartAvailable':
          report.dartAvailable,
      'javaAvailable':
          report.javaAvailable,
      'androidSdkAvailable':
          report.androidSdkAvailable,
      'offlineCapable':
          report.offlineCapable,
      'localBuildCapability':
          hasLocalBuildCapability,
      'offlineBuildCapability':
          hasOfflineBuildCapability,
      'localTargets':
          localTargets
              .map(
                (target) => target.name,
              )
              .toList(
                growable: false,
              ),
      'offlineTargets':
          offlineTargets
              .map(
                (target) => target.name,
              )
              .toList(
                growable: false,
              ),
      'targets': <String, dynamic>{
        for (final entry
            in report.targets.entries)
          entry.key.name:
              <String, dynamic>{
            'status':
                entry.value.status.name,
            'executionMode':
                entry.value
                    .executionMode
                    .name,
            'available':
                entry.value.isAvailable,
            'canBuildOffline':
                entry.value.canBuildOffline,
            'name':
                entry.value.name,
            'version':
                entry.value.version,
            'path':
                entry.value.path,
            'missingComponents':
                entry.value
                    .missingComponents,
            'message':
                entry.value.message,
          },
      },
      'message':
          report.message,
    };
  }

  /// Cancella il report in memoria.
  ///
  /// Non modifica la toolchain.
  void clearCache() {
    _lastReport = null;
    _lastInspectionAt = null;
  }

  void _updateTargetInCachedReport(
    WorkshopToolchainInfo info,
  ) {
    final report = _lastReport;

    if (report == null) {
      return;
    }

    final targets =
        <WorkshopBuildTarget,
            WorkshopToolchainInfo>{
      ...report.targets,
      info.target: info,
    };

    _lastReport =
        WorkshopLocalToolchainReport(
      checkedAt:
          report.checkedAt,
      flutterAvailable:
          report.flutterAvailable,
      dartAvailable:
          report.dartAvailable,
      javaAvailable:
          report.javaAvailable,
      androidSdkAvailable:
          report.androidSdkAvailable,
      offlineCapable:
          targets.values.any(
        (item) => item.canBuildOffline,
      ),
      targets:
          Map<WorkshopBuildTarget,
              WorkshopToolchainInfo>.unmodifiable(
        targets,
      ),
      flutterVersion:
          report.flutterVersion,
      dartVersion:
          report.dartVersion,
      javaVersion:
          report.javaVersion,
      androidSdkPath:
          report.androidSdkPath,
      message:
          report.message,
    );
  }
}

/// Decisione locale prodotta dal Service.
///
/// È solamente informativa/decisionale:
/// non avvia nessuna operazione.
final class WorkshopLocalToolchainDecision {
  const WorkshopLocalToolchainDecision({
    required this.target,
    required this.available,
    required this.offline,
    required this.mode,
    required this.reason,
    required this.missingComponents,
  });

  final WorkshopBuildTarget target;

  final bool available;
  final bool offline;

  final WorkshopBuildExecutionMode mode;

  final String reason;

  final List<String> missingComponents;

  bool get requiresRemoteBuilder =>
      mode ==
      WorkshopBuildExecutionMode.remote;

  bool get isLocal =>
      mode ==
          WorkshopBuildExecutionMode.local ||
      mode ==
          WorkshopBuildExecutionMode.offlineLocal;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'target': target.name,
      'available': available,
      'offline': offline,
      'mode': mode.name,
      'reason': reason,
      'missingComponents':
          List<String>.unmodifiable(
        missingComponents,
      ),
      'requiresRemoteBuilder':
          requiresRemoteBuilder,
      'isLocal': isLocal,
    };
  }
}
