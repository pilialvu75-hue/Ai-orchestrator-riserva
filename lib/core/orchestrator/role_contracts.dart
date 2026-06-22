enum OrchestratorRoleKind { orchestrator, engineer, architect, cloud }

abstract class RoleContract {
  const RoleContract(this.kind, {required this.enabled});

  final OrchestratorRoleKind kind;
  final bool enabled;
}

final class OrchestratorRole extends RoleContract {
  const OrchestratorRole({this.label = 'Orchestrator'})
      : super(OrchestratorRoleKind.orchestrator, enabled: true);

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
  const CloudRole({this.label = 'Cloud'})
      : super(OrchestratorRoleKind.cloud, enabled: false);

  final String label;
}

class RoleFallbackRegistry {
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

  RoleContract? resolve(OrchestratorRoleKind kind) {
    switch (kind) {
      case OrchestratorRoleKind.orchestrator:
        return orchestrator;
      case OrchestratorRoleKind.engineer:
        return engineer?.enabled == true ? engineer : orchestrator;
      case OrchestratorRoleKind.architect:
        return architect?.enabled == true ? architect : orchestrator;
      case OrchestratorRoleKind.cloud:
        return cloud?.enabled == true ? cloud : null;
    }
  }
}
