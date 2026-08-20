import 'workshop_task_contract.dart';
import 'workshop_task_resource_allocator.dart';

/// Motivo per cui una task può essere bloccata prima dell'esecuzione.
enum WorkshopTaskExecutionBlockReason {
  invalidTask,
  resourceUnavailable,
  networkUnavailable,
  insufficientCredits,
  minimumReserveViolation,
  capabilityMissing,
  modeMismatch,
  approvalRequired,
  forbiddenScope,
}

/// Decisione del guard prima dell'esecuzione.
///
/// Il guard non esegue nulla e non modifica alcun file.
/// Decide esclusivamente se una task può essere consegnata
/// all'executor.
final class WorkshopTaskExecutionGuardDecision {
  const WorkshopTaskExecutionGuardDecision.allowed({
    required this.taskId,
    required this.resource,
    this.providerId,
    String reason = 'Execution allowed.',
  })  : isAllowed = true,
        blockReason = null,
        message = reason;

  const WorkshopTaskExecutionGuardDecision.blocked({
    required this.taskId,
    required this.message,
    required this.blockReason,
    this.resource,
    this.providerId,
  }) : isAllowed = false;

  final String taskId;
  final WorkshopTaskResource? resource;
  final String? providerId;

  final bool isAllowed;

  final WorkshopTaskExecutionBlockReason? blockReason;

  final String message;

  bool get isBlocked => !isAllowed;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'resource': resource?.name,
      'providerId': providerId,
      'isAllowed': isAllowed,
      'blockReason': blockReason?.name,
      'message': message,
    };
  }
}

/// Politica di sicurezza applicata prima dell'esecuzione.
///
/// La politica è volutamente conservativa.
///
/// In particolare:
///
/// - una task non viene mai applicata automaticamente al repository reale;
/// - una task che richiede rete non parte senza rete;
/// - una task non può superare il proprio budget autorizzato;
/// - una risorsa deve possedere le capability necessarie;
/// - la modalità richiesta dalla task deve essere rispettata;
/// - il guard non esegue provider e non consuma crediti.
final class WorkshopTaskExecutionGuardPolicy {
  const WorkshopTaskExecutionGuardPolicy({
    this.requireApprovalForCodeChanges = true,
    this.requireApprovalForRepositoryWork = true,
    this.requireNetworkForRemoteResources = true,
    this.minimumCreditReserve = 0.25,
    this.allowCloudInLocalMode = false,
    this.allowLocalFallbackInCloudMode = false,
  });

  /// Le modifiche al codice devono rimanere in staging
  /// fino all'approvazione esplicita dell'utente.
  final bool requireApprovalForCodeChanges;

  /// Il lavoro sul repository reale richiede approvazione.
  final bool requireApprovalForRepositoryWork;

  final bool requireNetworkForRemoteResources;

  /// Riserva globale che non deve essere consumata.
  final double minimumCreditReserve;

  /// Local mode non può trasformarsi silenziosamente in Cloud.
  final bool allowCloudInLocalMode;

  /// Cloud mode non può degradare silenziosamente a Local.
  final bool allowLocalFallbackInCloudMode;
}

/// Guard di sicurezza dell'esecuzione delle task.
///
/// È deliberatamente un componente piccolo.
///
/// Non è:
///
/// - un orchestratore;
/// - un planner;
/// - un allocator;
/// - un executor;
/// - un provider AI.
///
/// Riceve una task e una decisione di allocazione già prodotta
/// dall'allocator e verifica se quella decisione può essere eseguita.
final class WorkshopTaskExecutionGuard {
  const WorkshopTaskExecutionGuard({
    this.policy = const WorkshopTaskExecutionGuardPolicy(),
  });

  final WorkshopTaskExecutionGuardPolicy policy;

  /// Verifica una task prima di consegnarla all'executor.
  WorkshopTaskExecutionGuardDecision check({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation allocation,
    required WorkshopResourceSnapshot resource,
    bool networkAvailable = true,
    bool approvalGranted = false,
  }) {
    if (task.id.trim().isEmpty) {
      return const WorkshopTaskExecutionGuardDecision.blocked(
        taskId: '',
        blockReason:
            WorkshopTaskExecutionBlockReason.invalidTask,
        message: 'Task id cannot be empty.',
      );
    }

    final modeDecision = _checkMode(
      task: task,
      allocation: allocation,
    );

    if (modeDecision != null) {
      return modeDecision;
    }

    if (!resource.isUsable) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason.resourceUnavailable,
        message:
            'The allocated resource is not usable.',
      );
    }

    if (policy.requireNetworkForRemoteResources &&
        allocation.requiresNetwork &&
        !networkAvailable) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason.networkUnavailable,
        message:
            'The allocated resource requires network access.',
      );
    }

    final budgetDecision = _checkBudget(
      task: task,
      allocation: allocation,
      resource: resource,
    );

    if (budgetDecision != null) {
      return budgetDecision;
    }

    final capabilityDecision = _checkCapabilities(
      task: task,
      allocation: allocation,
      resource: resource,
    );

    if (capabilityDecision != null) {
      return capabilityDecision;
    }

    final scopeDecision = _checkScope(task);

    if (scopeDecision != null) {
      return scopeDecision;
    }

    final approvalDecision = _checkApproval(
      task: task,
      allocation: allocation,
      approvalGranted: approvalGranted,
    );

    if (approvalDecision != null) {
      return approvalDecision;
    }

    return WorkshopTaskExecutionGuardDecision.allowed(
      taskId: task.id,
      resource: allocation.resource,
      providerId: allocation.providerId,
    );
  }

  WorkshopTaskExecutionGuardDecision? _checkMode({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation allocation,
  }) {
    switch (task.mode) {
      case WorkshopTaskMode.local:
        if (allocation.resource ==
            WorkshopTaskResource.local) {
          return null;
        }

        if (allocation.resource ==
                WorkshopTaskResource.cloud &&
            !policy.allowCloudInLocalMode) {
          return WorkshopTaskExecutionGuardDecision.blocked(
            taskId: task.id,
            resource: allocation.resource,
            providerId: allocation.providerId,
            blockReason:
                WorkshopTaskExecutionBlockReason.modeMismatch,
            message:
                'Cloud execution is not allowed in Local mode.',
          );
        }

        if (allocation.resource ==
                WorkshopTaskResource.githubAgent ||
            allocation.resource ==
                WorkshopTaskResource.githubActions ||
            allocation.resource ==
                WorkshopTaskResource.hybridAi) {
          return WorkshopTaskExecutionGuardDecision.blocked(
            taskId: task.id,
            resource: allocation.resource,
            providerId: allocation.providerId,
            blockReason:
                WorkshopTaskExecutionBlockReason.modeMismatch,
            message:
                'Remote execution is not allowed for this Local task.',
          );
        }

      case WorkshopTaskMode.github:
        if (allocation.resource ==
                WorkshopTaskResource.githubAgent ||
            allocation.resource ==
                WorkshopTaskResource.githubActions) {
          return null;
        }

        return WorkshopTaskExecutionGuardDecision.blocked(
          taskId: task.id,
          resource: allocation.resource,
          providerId: allocation.providerId,
          blockReason:
              WorkshopTaskExecutionBlockReason.modeMismatch,
          message:
              'The task requires a GitHub resource.',
        );

      case WorkshopTaskMode.hybrid:
        if (allocation.resource ==
                WorkshopTaskResource.hybridAi ||
            allocation.resource ==
                WorkshopTaskResource.local ||
            allocation.resource ==
                WorkshopTaskResource.githubAgent) {
          return null;
        }

      case WorkshopTaskMode.cloud:
        if (allocation.resource ==
            WorkshopTaskResource.cloud) {
          return null;
        }

        if (allocation.resource ==
                WorkshopTaskResource.local &&
            policy.allowLocalFallbackInCloudMode) {
          return null;
        }

        return WorkshopTaskExecutionGuardDecision.blocked(
          taskId: task.id,
          resource: allocation.resource,
          providerId: allocation.providerId,
          blockReason:
              WorkshopTaskExecutionBlockReason.modeMismatch,
          message:
              'The allocated resource does not match the requested mode.',
        );
    }

    return null;
  }

  WorkshopTaskExecutionGuardDecision? _checkBudget({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation allocation,
    required WorkshopResourceSnapshot resource,
  }) {
    final estimatedCost = allocation.estimatedCredits >
            0
        ? allocation.estimatedCredits
        : task.budget.estimatedCredits;

    if (!task.budget.canStart(
      estimatedCost: estimatedCost,
    )) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason
                .insufficientCredits,
        message:
            'The task budget does not allow this execution.',
      );
    }

    if (estimatedCost > 0 &&
        resource.availableCredits <
            estimatedCost + policy.minimumCreditReserve) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason
                .minimumReserveViolation,
        message:
            'Executing this task would violate the minimum credit reserve.',
      );
    }

    return null;
  }

  WorkshopTaskExecutionGuardDecision? _checkCapabilities({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation allocation,
    required WorkshopResourceSnapshot resource,
  }) {
    final required = _requiredCapabilities(task);

    for (final capability in required) {
      if (!resource.supports(capability)) {
        return WorkshopTaskExecutionGuardDecision.blocked(
          taskId: task.id,
          resource: allocation.resource,
          providerId: allocation.providerId,
          blockReason:
              WorkshopTaskExecutionBlockReason
                  .capabilityMissing,
          message:
              'Resource ${allocation.resource.name} '
              'does not provide capability ${capability.name}.',
        );
      }
    }

    return null;
  }

  List<WorkshopResourceCapability> _requiredCapabilities(
    WorkshopTaskContract task,
  ) {
    switch (task.kind) {
      case WorkshopTaskKind.analysis:
      case WorkshopTaskKind.planning:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.planning,
        ];

      case WorkshopTaskKind.codeGeneration:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.codeGeneration,
        ];

      case WorkshopTaskKind.codeModification:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.codeGeneration,
        ];

      case WorkshopTaskKind.test:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.testing,
        ];

      case WorkshopTaskKind.lint:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.staticAnalysis,
        ];

      case WorkshopTaskKind.build:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.localBuild,
        ];

      case WorkshopTaskKind.debugging:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.reasoning,
        ];

      case WorkshopTaskKind.documentation:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.documentation,
        ];

      case WorkshopTaskKind.review:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.codeReview,
        ];

      case WorkshopTaskKind.integration:
        return const <WorkshopResourceCapability>[
          WorkshopResourceCapability.repositoryWork,
        ];
    }
  }

  WorkshopTaskExecutionGuardDecision? _checkScope(
    WorkshopTaskContract task,
  ) {
    final scope = task.fileScope;

    final duplicatedForbidden =
        scope.forbidden.toSet().length !=
            scope.forbidden.length;

    if (duplicatedForbidden) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        blockReason:
            WorkshopTaskExecutionBlockReason.forbiddenScope,
        message:
            'Task contains duplicated forbidden paths.',
      );
    }

    final overlap = scope.readOnly
        .toSet()
        .intersection(scope.allowed.toSet());

    if (overlap.isNotEmpty) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        blockReason:
            WorkshopTaskExecutionBlockReason.forbiddenScope,
        message:
            'A file cannot be both read-only and writable.',
      );
    }

    return null;
  }

  WorkshopTaskExecutionGuardDecision? _checkApproval({
    required WorkshopTaskContract task,
    required WorkshopResourceAllocation allocation,
    required bool approvalGranted,
  }) {
    final modifiesCode =
        task.kind == WorkshopTaskKind.codeGeneration ||
        task.kind == WorkshopTaskKind.codeModification ||
        task.kind == WorkshopTaskKind.integration;

    final repositoryWork =
        allocation.resource ==
            WorkshopTaskResource.githubAgent ||
        allocation.resource ==
            WorkshopTaskResource.githubActions;

    if (modifiesCode &&
        policy.requireApprovalForCodeChanges &&
        !approvalGranted) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason.approvalRequired,
        message:
            'Code-changing execution requires explicit approval.',
      );
    }

    if (repositoryWork &&
        policy.requireApprovalForRepositoryWork &&
        !approvalGranted) {
      return WorkshopTaskExecutionGuardDecision.blocked(
        taskId: task.id,
        resource: allocation.resource,
        providerId: allocation.providerId,
        blockReason:
            WorkshopTaskExecutionBlockReason.approvalRequired,
        message:
            'Repository work requires explicit approval.',
      );
    }

    return null;
  }
}
