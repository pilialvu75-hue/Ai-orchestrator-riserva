import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_service.dart';

/// Preferenza operativa richiesta al Cantiere.
enum WorkshopExecutionPreference {
  automatic,
  local,
  offline,
  github,
  hybrid,
}

/// Vincoli operativi dichiarati dall'utente.
///
/// Esempi:
/// - telefono lento;
/// - batteria scarica;
/// - viaggio;
/// - rete assente;
/// - richiesta esplicita di GitHub;
/// - richiesta esplicita di lavoro offline.
final class WorkshopExecutionConstraints {
  const WorkshopExecutionConstraints({
    this.preference = WorkshopExecutionPreference.automatic,
    this.networkAvailable = true,
    this.deviceSlow = false,
    this.batteryLow = false,
    this.travelMode = false,
    this.githubAvailable = true,
    this.cloudAvailable = true,
  });

  final WorkshopExecutionPreference preference;

  final bool networkAvailable;
  final bool deviceSlow;
  final bool batteryLow;
  final bool travelMode;

  final bool githubAvailable;
  final bool cloudAvailable;

  bool get deviceConstrained =>
      deviceSlow || batteryLow;

  bool get offlinePreferred =>
      preference == WorkshopExecutionPreference.offline ||
      travelMode;
}

/// Motivo della decisione del router.
enum WorkshopExecutionRouteReason {
  explicitLocal,
  explicitOffline,
  explicitGithub,
  explicitHybrid,
  localToolchainAvailable,
  offlineToolchainAvailable,
  networkUnavailable,
  deviceConstrained,
  localToolchainUnavailable,
  githubUnavailable,
  noExecutionResource,
}

/// Decisione prodotta dal router.
///
/// Il router non esegue la task.
/// Restituisce esclusivamente una decisione.
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

  final WorkshopBuildExecutionMode mode;
  final WorkshopExecutionRouteReason reason;

  final String explanation;

  final bool networkRequired;
  final bool requiresGithub;
  final bool requiresCloudAi;
  final bool requiresLocalToolchain;

  final List<String> warnings;

  bool get isLocal =>
      mode == WorkshopBuildExecutionMode.local ||
      mode == WorkshopBuildExecutionMode.offlineLocal;

  bool get isOffline =>
      mode == WorkshopBuildExecutionMode.offlineLocal;

  bool get isRemote =>
      mode == WorkshopBuildExecutionMode.remote;

  bool get requiresRemoteBuilder =>
      mode == WorkshopBuildExecutionMode.remote;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'mode': mode.name,
      'reason': reason.name,
      'explanation': explanation,
      'networkRequired': networkRequired,
      'requiresGithub': requiresGithub,
      'requiresCloudAi': requiresCloudAi,
      'requiresLocalToolchain':
          requiresLocalToolchain,
      'warnings': warnings,
      'isLocal': isLocal,
      'isOffline': isOffline,
      'isRemote': isRemote,
    };
  }
}

/// Router operativo del Cantiere.
///
/// Responsabilità:
///
/// - scegliere LOCAL;
/// - scegliere OFFLINE LOCAL;
/// - scegliere REMOTE/GitHub;
/// - identificare HYBRID come percorso AI-assistito;
/// - rispettare i vincoli espliciti dell'utente;
/// - evitare operazioni remote inutili.
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
/// La modalità `hybrid` qui rappresenta una decisione di
/// orchestrazione. L'effettivo collegamento ai provider AI
/// verrà effettuato da un livello superiore.
final class WorkshopExecutionModeRouter {
  const WorkshopExecutionModeRouter({
    required this.toolchainService,
  });

  final WorkshopLocalToolchainService toolchainService;

  /// Calcola il percorso operativo.
  WorkshopExecutionRoute route({
    required WorkshopBuildTarget target,
    WorkshopExecutionConstraints constraints =
        const WorkshopExecutionConstraints(),
  }) {
    final localAvailable =
        _localAvailable(target);

    final offlineAvailable =
        _offlineAvailable(target);

    // ----------------------------------------------------------
    // 1. OFFLINE esplicito.
    // ----------------------------------------------------------
    if (constraints.preference ==
        WorkshopExecutionPreference.offline) {
      if (offlineAvailable) {
        return const WorkshopExecutionRoute(
          mode:
              WorkshopBuildExecutionMode.offlineLocal,
          reason:
              WorkshopExecutionRouteReason.explicitOffline,
          explanation:
              'Offline execution was explicitly requested '
              'and the target is available locally.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }

      return const WorkshopExecutionRoute(
        mode:
            WorkshopBuildExecutionMode.offlineLocal,
        reason:
            WorkshopExecutionRouteReason.explicitOffline,
        explanation:
            'Offline execution was explicitly requested, '
            'but the target is not confirmed as locally available.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
        warnings: <String>[
          'Offline execution cannot currently be confirmed.',
          'No remote fallback is selected automatically.',
        ],
      );
    }

    // ----------------------------------------------------------
    // 2. GitHub esplicito.
    // ----------------------------------------------------------
    if (constraints.preference ==
        WorkshopExecutionPreference.github) {
      if (constraints.githubAvailable &&
          constraints.networkAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopBuildExecutionMode.remote,
          reason:
              WorkshopExecutionRouteReason.explicitGithub,
          explanation:
              'GitHub remote execution was explicitly requested.',
          networkRequired: true,
          requiresGithub: true,
          requiresCloudAi: false,
          requiresLocalToolchain: false,
        );
      }

      return const WorkshopExecutionRoute(
        mode: WorkshopBuildExecutionMode.remote,
        reason:
            WorkshopExecutionRouteReason.githubUnavailable,
        explanation:
            'GitHub execution was requested but is not currently '
            'available.',
        networkRequired: true,
        requiresGithub: true,
        requiresCloudAi: false,
        requiresLocalToolchain: false,
        warnings: <String>[
          'GitHub execution cannot currently be started.',
        ],
      );
    }

    // ----------------------------------------------------------
    // 3. HYBRID esplicito.
    // ----------------------------------------------------------
    if (constraints.preference ==
        WorkshopExecutionPreference.hybrid) {
      if (constraints.cloudAvailable &&
          constraints.networkAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopBuildExecutionMode.remote,
          reason:
              WorkshopExecutionRouteReason.explicitHybrid,
          explanation:
              'Hybrid execution was explicitly requested. '
              'The higher-level AI coordinator may combine local '
              'execution with available cloud AI resources.',
          networkRequired: true,
          requiresGithub: false,
          requiresCloudAi: true,
          requiresLocalToolchain: false,
        );
      }

      if (localAvailable) {
        return WorkshopExecutionRoute(
          mode: offlineAvailable
              ? WorkshopBuildExecutionMode.offlineLocal
              : WorkshopBuildExecutionMode.local,
          reason:
              WorkshopExecutionRouteReason.localToolchainAvailable,
          explanation:
              'Hybrid resources are unavailable; '
              'local execution remains available.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
          warnings: const <String>[
            'Cloud AI is currently unavailable.',
            'Falling back to local execution.',
          ],
        );
      }
    }

    // ----------------------------------------------------------
    // 4. LOCAL esplicito.
    // ----------------------------------------------------------
    if (constraints.preference ==
        WorkshopExecutionPreference.local) {
      if (localAvailable) {
        return WorkshopExecutionRoute(
          mode: offlineAvailable
              ? WorkshopBuildExecutionMode.offlineLocal
              : WorkshopBuildExecutionMode.local,
          reason:
              WorkshopExecutionRouteReason.explicitLocal,
          explanation:
              offlineAvailable
                  ? 'Local execution was requested and '
                    'the target is available offline.'
                  : 'Local execution was requested and '
                    'the target is available locally.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }

      return const WorkshopExecutionRoute(
        mode: WorkshopBuildExecutionMode.local,
        reason:
            WorkshopExecutionRouteReason.localToolchainUnavailable,
        explanation:
            'Local execution was explicitly requested but '
            'the required local toolchain is unavailable.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
        warnings: <String>[
          'Required local toolchain is unavailable.',
        ],
      );
    }

    // ----------------------------------------------------------
    // 5. Nessuna rete.
    // ----------------------------------------------------------
    if (!constraints.networkAvailable) {
      if (offlineAvailable) {
        return const WorkshopExecutionRoute(
          mode:
              WorkshopBuildExecutionMode.offlineLocal,
          reason:
              WorkshopExecutionRouteReason.networkUnavailable,
          explanation:
              'Network is unavailable and the target can '
              'be executed locally offline.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }

      if (localAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopBuildExecutionMode.local,
          reason:
              WorkshopExecutionRouteReason.networkUnavailable,
          explanation:
              'Network is unavailable. Local execution is '
              'available, but offline capability was not confirmed.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
          warnings: <String>[
            'Offline dependency availability was not confirmed.',
          ],
        );
      }

      return const WorkshopExecutionRoute(
        mode:
            WorkshopBuildExecutionMode.offlineLocal,
        reason:
            WorkshopExecutionRouteReason.noExecutionResource,
        explanation:
            'Network is unavailable and the requested target '
            'is not locally available.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: false,
        warnings: <String>[
          'No local execution capability is available.',
          'Remote execution cannot be requested without network.',
        ],
      );
    }

    // ----------------------------------------------------------
    // 6. Telefono lento / batteria bassa.
    //
    // In automatic mode preferiamo il builder remoto se
    // disponibile, evitando di consumare inutilmente il telefono.
    // ----------------------------------------------------------
    if (constraints.deviceConstrained) {
      if (constraints.githubAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopBuildExecutionMode.remote,
          reason:
              WorkshopExecutionRouteReason.deviceConstrained,
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
          mode: WorkshopBuildExecutionMode.remote,
          reason:
              WorkshopExecutionRouteReason.deviceConstrained,
          explanation:
              'The device is constrained and GitHub is '
              'unavailable. Cloud-assisted execution is available.',
          networkRequired: true,
          requiresGithub: false,
          requiresCloudAi: true,
          requiresLocalToolchain: false,
        );
      }

      if (localAvailable) {
        return WorkshopExecutionRoute(
          mode: offlineAvailable
              ? WorkshopBuildExecutionMode.offlineLocal
              : WorkshopBuildExecutionMode.local,
          reason:
              WorkshopExecutionRouteReason.deviceConstrained,
          explanation:
              'Remote resources are unavailable; local execution '
              'is the remaining available option.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
          warnings: const <String>[
            'Device is constrained.',
            'Remote resources were unavailable.',
          ],
        );
      }
    }

    // ----------------------------------------------------------
    // 7. Modalità viaggio.
    //
    // Se l'utente è in viaggio, preferiamo offline quando
    // possibile, ma senza impedire il lavoro locale normale.
    // ----------------------------------------------------------
    if (constraints.travelMode) {
      if (offlineAvailable) {
        return const WorkshopExecutionRoute(
          mode:
              WorkshopBuildExecutionMode.offlineLocal,
          reason:
              WorkshopExecutionRouteReason.offlineToolchainAvailable,
          explanation:
              'Travel mode is active and offline local '
              'execution is available.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }

      if (localAvailable) {
        return const WorkshopExecutionRoute(
          mode: WorkshopBuildExecutionMode.local,
          reason:
              WorkshopExecutionRouteReason.localToolchainAvailable,
          explanation:
              'Travel mode is active. Local execution is '
              'available although offline capability was not confirmed.',
          networkRequired: false,
          requiresGithub: false,
          requiresCloudAi: false,
          requiresLocalToolchain: true,
        );
      }
    }

    // ----------------------------------------------------------
    // 8. Automatico: LOCAL prima.
    //
    // Evitiamo di consumare risorse remote quando il telefono
    // è perfettamente in grado di svolgere la task.
    // ----------------------------------------------------------
    if (localAvailable) {
      return WorkshopExecutionRoute(
        mode: offlineAvailable
            ? WorkshopBuildExecutionMode.offlineLocal
            : WorkshopBuildExecutionMode.local,
        reason: offlineAvailable
            ? WorkshopExecutionRouteReason
                .offlineToolchainAvailable
            : WorkshopExecutionRouteReason
                .localToolchainAvailable,
        explanation: offlineAvailable
            ? 'Local execution is available offline.'
            : 'Local execution is available.',
        networkRequired: false,
        requiresGithub: false,
        requiresCloudAi: false,
        requiresLocalToolchain: true,
      );
    }

    // ----------------------------------------------------------
    // 9. Automatico: GitHub come builder.
    // ----------------------------------------------------------
    if (constraints.githubAvailable) {
      return const WorkshopExecutionRoute(
        mode: WorkshopBuildExecutionMode.remote,
        reason:
            WorkshopExecutionRouteReason
                .localToolchainUnavailable,
        explanation:
            'The target is not available locally. '
            'GitHub is available as a remote builder.',
        networkRequired: true,
        requiresGithub: true,
        requiresCloudAi: false,
        requiresLocalToolchain: false,
      );
    }

    // ----------------------------------------------------------
    // 10. Automatico: cloud AI / HYBRID.
    // ----------------------------------------------------------
    if (constraints.cloudAvailable) {
      return const WorkshopExecutionRoute(
        mode: WorkshopBuildExecutionMode.remote,
        reason:
            WorkshopExecutionRouteReason
                .localToolchainUnavailable,
        explanation:
            'Local and GitHub build resources are unavailable. '
            'Cloud-assisted orchestration remains available.',
        networkRequired: true,
        requiresGithub: false,
        requiresCloudAi: true,
        requiresLocalToolchain: false,
      );
    }

    // ----------------------------------------------------------
    // 11. Nessuna risorsa.
    // ----------------------------------------------------------
    return const WorkshopExecutionRoute(
      mode: WorkshopBuildExecutionMode.remote,
      reason:
          WorkshopExecutionRouteReason.noExecutionResource,
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

  bool _localAvailable(
    WorkshopBuildTarget target,
  ) {
    return toolchainService.canBuildLocally(target);
  }

  bool _offlineAvailable(
    WorkshopBuildTarget target,
  ) {
    return toolchainService.canBuildOffline(target);
  }
}
