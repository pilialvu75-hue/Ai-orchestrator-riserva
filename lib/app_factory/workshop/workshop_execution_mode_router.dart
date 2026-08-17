import 'workshop_local_toolchain_service.dart';

/// Modalità operative del Cantiere.
///
/// Il router sceglie il percorso, ma non esegue direttamente
/// l'operazione.
enum WorkshopExecutionMode {
  local,
  offline,
  github,
  hybrid,
}

/// Motivo principale della scelta del router.
enum WorkshopExecutionReason {
  explicitOfflineRequest,
  explicitGithubRequest,
  explicitHybridRequest,
  localToolchainAvailable,
  localToolchainUnavailable,
  offlinePreferred,
  networkUnavailable,
  deviceConstrained,
  cloudPreferred,
  hybridPreferred,
  noLocalCapability,
}

/// Vincoli dichiarati dall'utente.
///
/// Questi valori possono essere prodotti dalla UI in futuro:
///
/// - "telefono lento"
/// - "batteria scarica"
/// - "sono in viaggio"
/// - "problemi di rete"
/// - "fai tutto online"
/// - "fai tutto offline"
final class WorkshopExecutionConstraints {
  const WorkshopExecutionConstraints({
    this.forceOffline = false,
    this.forceGithub = false,
    this.preferHybrid = false,
    this.networkAvailable = true,
    this.deviceSlow = false,
    this.batteryLow = false,
    this.travelMode = false,
    this.cloudAvailable = true,
    this.githubAvailable = true,
  });

  final bool forceOffline;
  final bool forceGithub;
  final bool preferHybrid;

  final bool networkAvailable;

  final bool deviceSlow;
  final bool batteryLow;
  final bool travelMode;

  final bool cloudAvailable;
  final bool githubAvailable;

  bool get deviceConstrained =>
      deviceSlow || batteryLow;

  bool get offlinePreferred =>
      forceOffline || travelMode;

  bool get remotePreferred =>
      forceGithub ||
      deviceConstrained;
}

/// Decisione prodotta dal router.
///
/// È un contratto decisionale e non esegue alcuna operazione.
final class WorkshopExecutionRoute {
  const WorkshopExecutionRoute({
    required this.mode,
    required this.reason,
    required this.explanation,
    required this.networkRequired,
    required this.requiresGithub,
    required this.requiresCloudAi,
    required this.requiresLocalToolchain,
    this.warnings = const <String>[],
  });

  final WorkshopExecutionMode mode;

  final WorkshopExecutionReason reason;

  final String explanation;

  final bool networkRequired;
  final bool requiresGithub;
  final bool requiresCloudAi;
  final bool requiresLocalToolchain;

  final List<String> warnings;

  bool get isLocal =>
      mode == WorkshopExecutionMode.local ||
      mode == WorkshopExecutionMode.offline;

  bool get isOffline =>
      mode == WorkshopExecutionMode.offline;

  bool get isRemote =>
      mode == WorkshopExecutionMode.github ||
      mode == WorkshopExecutionMode.hybrid;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'mode': mode.name,
      'reason': reason.name,
      'explanation': explanation,
      'networkRequired': networkRequired,
      'requiresGithub': requiresGithub,
      'requiresCloudAi': requiresCloudAi,
      'requiresLocalToolchain': requiresLocalToolchain,
      'warnings': warnings,
    };
  }
}

/// Router principale del Cantiere.
///
/// Responsabilità:
///
/// - scegliere LOCAL;
/// - scegliere OFFLINE;
/// - scegliere GITHUB;
/// - scegliere HYBRID;
/// - rispettare i vincoli espliciti dell'utente;
/// - evitare di consumare risorse remote inutilmente.
///
/// NON:
///
/// - esegue comandi;
/// - avvia build;
/// - chiama GitHub;
/// - chiama OpenAI/Gemini/Claude/Grok;
/// - consuma crediti;
/// - modifica file.
///
/// Il router produce esclusivamente una decisione.
final class WorkshopExecutionModeRouter {
  const WorkshopExecutionModeRouter({
    required this.toolchainService,
  });

  final WorkshopLocalToolchainService toolchainService;

  /// Calcola il percorso operativo.
  WorkshopExecutionRoute route({
    required WorkshopExecutionConstraints constraints,
    String? target,
  }) {
    // 1. Richiesta esplicita OFFLINE:
    //
    // Ha precedenza su qualsiasi preferenza automatica.
    if (constraints.forceOffline) {
      return _offlineRoute(
        constraints,
        target: target,
      );
    }

    // 2. Richiesta esplicita GitHub.
    if (constraints.forceGithub) {
      if (constraints.githubAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.github,
          reason: WorkshopExecutionReason.explicitGithubRequest,
          explanation:
              'The user explicitly requested GitHub execution.',
          networkRequired: true,
          requiresGithub: true,
          requiresCloudAi: false,
          requiresLocalToolchain: false,
        );
      }

      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.local,
        reason: WorkshopExecutionReason.localToolchainAvailable,
        explanation:
            'GitHub was requested but is unavailable. '
            'Local execution remains available.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
        warnings: <String>[
          'GitHub was explicitly requested but is unavailable.',
        ],
      );
    }

    // 3. HYBRID esplicito.
    if (constraints.preferHybrid) {
      if (constraints.cloudAvailable &&
          constraints.networkAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.hybrid,
          reason: WorkshopExecutionReason.explicitHybridRequest,
          explanation:
              'Hybrid execution was explicitly preferred.',
          networkRequired: true,
          requiresGithub: false,
          requiresCloudAi: true,
          requiresLocalToolchain: false,
        );
      }

      // Se HYBRID non è disponibile, proviamo LOCAL.
      if (target != null &&
          _localAvailable(target)) {
        return const WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.local,
          reason: WorkshopExecutionReason.localToolchainAvailable,
          explanation:
              'Hybrid execution is unavailable; '
              'local execution is available.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }
    }

    // 4. Nessuna rete:
    //
    // Non tentiamo GitHub né AI cloud.
    if (!constraints.networkAvailable) {
      if (target != null &&
          _localAvailable(target)) {
        return WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.offline,
          reason: WorkshopExecutionReason.networkUnavailable,
          explanation:
              'Network is unavailable and local execution '
              'is available.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }

      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.offline,
        reason: WorkshopExecutionReason.noLocalCapability,
        explanation:
            'Network is unavailable and no remote execution '
            'can be requested.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: false,
        warnings: <String>[
          'No local capability was confirmed.',
          'Remote execution is unavailable without network.',
        ],
      );
    }

    // 5. Telefono lento / batteria bassa:
    //
    // Evitiamo di forzare il telefono se abbiamo un builder remoto.
    if (constraints.remotePreferred) {
      if (constraints.githubAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.github,
          reason: WorkshopExecutionReason.deviceConstrained,
          explanation:
              'The device is constrained, so remote GitHub '
              'execution is preferred.',
          networkRequired: true,
          requiresGithub: true,
          requiresCloudAi: false,
          requiresLocalToolchain: false,
        );
      }

      if (constraints.cloudAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopExecutionMode.hybrid,
          reason: WorkshopExecutionReason.deviceConstrained,
          explanation:
              'The device is constrained and GitHub is unavailable; '
              'cloud-assisted execution is preferred.',
          networkRequired: true,
          requiresGithub: false,
          requiresCloudAi: true,
          requiresLocalToolchain: false,
        );
      }
    }

    // 6. LOCAL normale.
    if (target != null &&
        _localAvailable(target)) {
      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.local,
        reason: WorkshopExecutionReason.localToolchainAvailable,
        explanation:
            'The requested target is available locally.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
      );
    }

    // 7. GitHub come builder remoto.
    if (constraints.githubAvailable) {
      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.github,
        reason: WorkshopExecutionReason.localToolchainUnavailable,
        explanation:
            'The local toolchain is unavailable; '
            'GitHub is available as a remote builder.',
        networkRequired: true,
        requiresGithub: true,
        requiresCloudAi: false,
        requiresLocalToolchain: false,
      );
    }

    // 8. HYBRID come fallback AI.
    if (constraints.cloudAvailable) {
      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.hybrid,
        reason: WorkshopExecutionReason.cloudPreferred,
        explanation:
            'Local and GitHub execution are unavailable; '
            'cloud-assisted execution remains available.',
        networkRequired: true,
        requiresGithub: false,
        requiresCloudAi: true,
        requiresLocalToolchain: false,
      );
    }

    // 9. Nessuna risorsa disponibile.
    return const WorkshopExecutionRoute(
      mode: WorkshopExecutionMode.offline,
      reason: WorkshopExecutionReason.noLocalCapability,
      explanation:
          'No usable local or remote execution resource '
          'is currently available.',
      networkRequired: false,
      requiresGithub: false,
      requiresCloudAi: false,
      requiresLocalToolchain: false,
      warnings: <String>[
        'No execution resource is currently available.',
      ],
    );
  }

  WorkshopExecutionRoute _offlineRoute(
    WorkshopExecutionConstraints constraints, {
    String? target,
  }) {
    if (target != null &&
        _localAvailable(target)) {
      return const WorkshopExecutionRoute(
        mode: WorkshopExecutionMode.offline,
        reason: WorkshopExecutionReason.explicitOfflineRequest,
        explanation:
            'Offline execution was explicitly requested '
            'and local execution is available.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
      );
    }

    return const WorkshopExecutionRoute(
      mode: WorkshopExecutionMode.offline,
      reason: WorkshopExecutionReason.explicitOfflineRequest,
      explanation:
          'Offline execution was explicitly requested, '
          'but local toolchain capability is not confirmed.',
      networkRequired: false,
      requiresGithub: false,
      requiresCloudAi: false,
      requiresLocalToolchain: false,
      warnings: <String>[
        'Requested offline mode cannot guarantee execution.',
        'No remote fallback will be attempted automatically.',
      ],
    );
  }

  bool _localAvailable(String target) {
    // Il router non conosce direttamente Flutter, Dart o Android SDK.
    //
    // Per ora utilizziamo il service solo se il target corrisponde
    // a una capability già esposta dal report.
    //
    // Il collegamento definitivo con WorkshopBuildTarget verrà
    // effettuato nel componente adapter successivo.
    final report = toolchainService.lastReport;

    if (report == null) {
      return false;
    }

    for (final entry in report.targets.entries) {
      if (entry.key.name == target &&
          entry.value.isAvailable) {
        return true;
      }
    }

    return false;
  }
}
