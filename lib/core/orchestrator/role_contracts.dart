enum OrchestratorRoleKind { orchestrator, engineer, architect, cloud }

abstract class RoleContract {
  const RoleContract(this.kind, {required this.enabled});

  final OrchestratorRoleKind kind;
  final bool enabled;
}

final class OrchestratorRole extends RoleContract {
  const OrchestratorRole({this.label = 'Orchestrator', bool enabled = true})
      : super(OrchestratorRoleKind.orchestrator, enabled: enabled);

  final String label;
}

final class EngineerRole extends RoleContract {
  const EngineerRole({this.label = 'Engineer', bool enabled = true})
      : super(OrchestratorRoleKind.engineer, enabled: enabled);

  final String label;
}

final class ArchitectRole extends RoleContract {
  const ArchitectRole({this.label = 'Architect', bool enabled = true})
      : super(OrchestratorRoleKind.architect, enabled: enabled);

  final String label;
}

final class CloudRole extends RoleContract {
  const CloudRole({this.label = 'Cloud', bool enabled = false})
      : super(OrchestratorRoleKind.cloud, enabled: enabled);

  final String label;
}

final class RoleFallbackRegistry {
  const RoleFallbackRegistry({
    required this.orchestrator,
    this.engineer,
    this.architect,
    this.cloud,
  });

  final OrchestratorRole orchestrator;
  final EngineerRole? engineer;
  final ArchitectRole? architect;
  final CloudRole? cloud;

  /// Resolves the requested role.
  ///
  /// Engineer and Architect fall back to the active orchestrator binding when
  /// they are missing or disabled.
  ///
  /// [OrchestratorRoleKind.orchestrator] always returns the primary
  /// orchestrator binding. [OrchestratorRoleKind.cloud] always throws
  /// [UnsupportedError] because CloudRole remains disabled under the current
  /// runtime policy.
  RoleContract resolve(OrchestratorRoleKind kind) {
    switch (kind) {
      case OrchestratorRoleKind.orchestrator:
        return orchestrator;
      case OrchestratorRoleKind.engineer:
        return _resolveFallback(engineer, orchestrator);
      case OrchestratorRoleKind.architect:
        return _resolveFallback(architect, orchestrator);
      case OrchestratorRoleKind.cloud:
        throw UnsupportedError(
          'CloudRole cannot be resolved because it is disabled by policy. '
          'Use orchestrator, engineer, or architect instead.',
        );
    }
  }

  RoleContract _resolveFallback(RoleContract? role, RoleContract fallback) {
    return (role?.enabled ?? false) ? role! : fallback;
  }
}
