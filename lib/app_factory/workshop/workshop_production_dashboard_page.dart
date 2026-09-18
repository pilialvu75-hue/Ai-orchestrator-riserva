import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_repair.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_conversation_selection.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Production shell for the guarded Cantiere pipeline.
///
/// Long-running inference is owned by [executionController], outside this
/// widget. Rebuilding or detaching the page therefore cannot start duplicate
/// work. Reviewer validation and explicit owner approval remain the only path
/// to workspace mutation.
final class WorkshopProductionDashboardPage extends StatefulWidget {
  const WorkshopProductionDashboardPage({
    super.key,
    required this.bundle,
    required this.modelAssignments,
    required this.executionController,
    required this.chatController,
  });

  final WorkshopProductionLifecycleBundle bundle;
  final List<WorkshopModelAssignment> modelAssignments;
  final WorkshopProductionExecutionController executionController;
  final WorkshopChatController chatController;

  @override
  State<WorkshopProductionDashboardPage> createState() =>
      _WorkshopProductionDashboardPageState();
}

class _WorkshopProductionDashboardPageState
    extends State<WorkshopProductionDashboardPage> {
  late final WorkshopProductionTaskCoordinator _coordinator;
  late final WorkshopBuildRepairPreparer _repairPreparer;
  WorkshopBuildResult? _buildResult;
  bool _mutationBusy = false;
  bool _autoAdvanceScheduled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _coordinator = WorkshopProductionTaskCoordinator(bundle: widget.bundle);
    _repairPreparer = WorkshopBuildRepairPreparer(bundle: widget.bundle);
    widget.bundle.dashboardController.addListener(_onLifecycleChanged);
    widget.executionController.addListener(_onLifecycleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleAutoAdvance());
  }

  @override
  void dispose() {
    widget.bundle.dashboardController.removeListener(_onLifecycleChanged);
    widget.executionController.removeListener(_onLifecycleChanged);
    super.dispose();
  }

  void _onLifecycleChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleAutoAdvance();
  }

  void _scheduleAutoAdvance() {
    if (!mounted || _autoAdvanceScheduled) return;
    _autoAdvanceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _autoAdvanceScheduled = false;
      if (mounted) await _autoAdvance();
    });
  }

  Future<void> _autoAdvance() async {
    if (_mutationBusy || widget.executionController.state.isRunning) return;
    final taskId = _activeTaskId;
    final execution = widget.executionController.state;

    if (taskId != null && taskId.isNotEmpty) {
      if (execution.status == WorkshopProductionExecutionStatus.idle) {
        await _runPreparedTask();
      } else if (execution.status ==
              WorkshopProductionExecutionStatus.succeeded &&
          _currentInferenceResult?.readyForApproval == true &&
          _projectApprovalAuthorizesCurrentProject) {
        await _approveAndApplyValidatedTask();
      }
      return;
    }

    if (_projectReadyForBuild && _buildResult == null) {
      await _buildCompletedProject();
    }
  }

  Future<void> _runPreparedTask({bool retry = false}) async {
    if (_mutationBusy || widget.executionController.state.isRunning) return;
    final taskId = _activeTaskId;
    if (taskId == null || taskId.isEmpty) return;

    setState(() => _error = null);
    try {
      final result = retry
          ? await widget.executionController.retry()
          : await widget.executionController.start(
              isOffline: widget.executionController.state.isOffline,
            );
      if (!mounted) return;
      if (!result.readyForApproval) {
        setState(() {
          _error = 'Il task è stato elaborato ma non ha superato la revisione.';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Esecuzione del task non riuscita: $error');
    }
  }

  bool get _projectApprovalAuthorizesCurrentProject {
    final state = widget.bundle.dashboardController.state;
    return state.isProjectApproved;
  }

  /// Continues an already owner-authorized project without asking a
  /// non-programmer to approve every generated file. This path is reachable
  /// only after Engineer output has passed Reviewer + validation and therefore
  /// preserves all existing workspace safety gates.
  Future<void> _approveAndApplyValidatedTask() async {
    final handle = _currentHandle;
    final result = _currentInferenceResult;
    if (_mutationBusy ||
        handle == null ||
        result == null ||
        !result.readyForApproval ||
        !_projectApprovalAuthorizesCurrentProject ||
        handle.session.status != WorkspaceSessionStatus.validation) {
      return;
    }

    try {
      _coordinator.decide(
        handle: handle,
        decision: WorkshopApplyDecision.approve,
      );
      await _applyApprovedTask();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Continuazione autonoma del task non riuscita: $error';
        });
      }
    }
  }

  Future<void> _reviewChanges() async {
    final handle = _currentHandle;
    final result = _currentInferenceResult;
    if (handle == null || result == null || !result.readyForApproval) return;

    final decision = await showDialog<WorkshopApplyDecision>(
      context: context,
      builder: (dialogContext) {
        final files = handle.session.diff.files;
        final validation = result.validation;
        return AlertDialog(
          title: const Text('Revisione modifiche Cantiere'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Reviewer: ${result.review.summary}'),
                  const SizedBox(height: 8),
                  Text('Validazione: ${validation?.summary ?? 'non disponibile'}'),
                  const SizedBox(height: 16),
                  Text('File modificati (${files.length})',
                      style: Theme.of(dialogContext).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (files.isEmpty)
                    const Text('Nessuna modifica staged.')
                  else
                    ...files.map((file) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('${file.changeType.name}: ${file.path}'),
                        )),
                  if (result.review.findings.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('Osservazioni Reviewer',
                        style: Theme.of(dialogContext).textTheme.titleSmall),
                    ...result.review.findings.map(Text.new),
                  ],
                  if (result.review.warnings.isNotEmpty ||
                      (validation?.warnings.isNotEmpty ?? false)) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('Avvisi',
                        style: Theme.of(dialogContext).textTheme.titleSmall),
                    ...result.review.warnings.map(Text.new),
                    ...?validation?.warnings.map(Text.new),
                  ],
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Chiudi'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(WorkshopApplyDecision.reject),
              child: const Text('Rifiuta'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(WorkshopApplyDecision.approve),
              child: const Text('Approva e continua'),
            ),
          ],
        );
      },
    );

    if (decision == null || !mounted) return;
    try {
      _coordinator.decide(handle: handle, decision: decision);
      if (decision == WorkshopApplyDecision.reject) {
        setState(() => _error = 'Modifiche rifiutate dal proprietario.');
        return;
      }
      await _applyApprovedTask();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Decisione sulle modifiche non riuscita: $error');
      }
    }
  }

  Future<void> _applyApprovedTask() async {
    final handle = _currentHandle;
    if (_mutationBusy ||
        handle == null ||
        handle.session.status != WorkspaceSessionStatus.approved ||
        !handle.session.isApplyApproved) {
      return;
    }

    setState(() {
      _mutationBusy = true;
      _error = null;
    });
    try {
      await _coordinator.applyApproved(handle: handle);
      await widget.executionController.markCurrentExecutionCompleted();
      if (!mounted) return;
      widget.executionController.resetForNextTask();

      if (!_projectReadyForBuild) {
        final session = await widget.bundle.dashboardController.prepareNextTask();
        if (!mounted) return;
        if (session == null && !_projectReadyForBuild) {
          setState(() {
            _error =
                'Il progetto non è completo e non esiste un altro task eseguibile.';
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Applicazione delle modifiche non riuscita: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
        _scheduleAutoAdvance();
      }
    }
  }

  Future<bool> _closeProjectForNewConversation() async {
    if (_mutationBusy) {
      return false;
    }

    setState(() {
      _mutationBusy = true;
      _error = null;
    });

    try {
      await widget.executionController.cancelAndWait();

      await widget.executionController.abandonCurrentExecution();

      if (widget.executionController.state.status !=
          WorkshopProductionExecutionStatus.idle) {
        widget.executionController.reset();
      }

      widget.bundle.dashboardController.cancelProduction();
      widget.bundle.dashboardController.forgetProduction();
      widget.executionController.clearBuildRepairChain();

      if (!mounted) {
        return true;
      }

      setState(() {
        _buildResult = null;
        _error = null;
      });

      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Chiusura del progetto non riuscita: $error';
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
      }
    }
  }

  Future<void> _buildCompletedProject() async {
    if (_mutationBusy || !_projectReadyForBuild || _buildResult != null) return;
    final failedPlan = _activePlan;
    if (failedPlan == null) return;

    setState(() {
      _mutationBusy = true;
      _error = null;
    });
    try {
      final isOffline = widget.executionController.state.isOffline;
      final result = await _coordinator.buildWorkspace(
        target: WorkshopBuildTarget.android,
        mode: isOffline
            ? WorkshopBuildExecutionMode.offlineLocal
            : WorkshopBuildExecutionMode.automatic,
      );
      if (!mounted) return;

      final planner = _repairPreparer.planner;
      final assessment = planner.assess(result);
      if (assessment.isVerifiedSuccess) {
        widget.executionController.clearBuildRepairChain();
        setState(() {
          _buildResult = result;
          _error = null;
        });
        return;
      }

      if (assessment.isRepairable) {
        final rootProjectId =
            widget.executionController.buildRepairRootProjectId ?? failedPlan.id;
        final reservation = widget.executionController.reserveBuildRepairAttempt(
          rootProjectId: rootProjectId,
          failureSignature: planner.failureSignature(result),
        );

        if (reservation == WorkshopBuildRepairReservation.repeatedFailure) {
          setState(() {
            _buildResult = result;
            _error =
                'Build non riuscita: il repair ha prodotto lo stesso guasto '
                'del tentativo precedente. Catena interrotta per evitare un loop.';
          });
          return;
        }

        if (reservation == WorkshopBuildRepairReservation.budgetExhausted) {
          setState(() {
            _buildResult = result;
            _error =
                'Build non riuscita e limite di riparazione automatica raggiunto '
                '(${widget.executionController.policy.maxBuildRepairAttempts}).';
          });
          return;
        }

        final repairNumber = widget.executionController.buildRepairAttempts;
        await _repairPreparer.prepare(
          failedPlan: failedPlan,
          failedBuild: result,
          repairNumber: repairNumber,
        );
        if (!mounted) return;

        widget.executionController.resetForNextTask();
        setState(() {
          _buildResult = null;
          _error = null;
        });
        _scheduleAutoAdvance();
        return;
      }

      widget.executionController.clearBuildRepairChain();
      setState(() {
        _buildResult = result;
        _error = assessment.disposition == WorkshopBuildDisposition.cancelled
            ? 'Build finale annullata.'
            : 'Build finale non riparabile automaticamente: '
                '${assessment.reason ?? result.message ?? result.status.name}';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Build finale del progetto non riuscita: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
        _scheduleAutoAdvance();
      }
    }
  }

  String? get _activeTaskId =>
      widget.bundle.dashboardController.state.activeTaskId?.trim();

  WorkshopProjectPlan? get _activePlan {
    final requestId = widget.bundle.dashboardController.state.requestId?.trim();
    if (requestId == null || requestId.isEmpty) return null;
    return widget.bundle.dashboardController.engine.planOf(requestId);
  }

  bool get _projectReadyForBuild {
    final state = widget.bundle.dashboardController.state;
    final activeTaskId = state.activeTaskId?.trim();
    if (state.requestId == null ||
        state.requestId!.trim().isEmpty ||
        (activeTaskId != null && activeTaskId.isNotEmpty)) {
      return false;
    }
    final plan = _activePlan;
    return plan != null &&
        plan.isComplete &&
        plan.tasks.isNotEmpty &&
        plan.tasks.every((task) => task.completed);
  }

  WorkshopProductionTaskHandle? get _currentHandle {
    final handle = widget.executionController.state.handle;
    final activeTaskId = _activeTaskId;
    if (handle == null || activeTaskId == null || handle.taskId != activeTaskId) {
      return null;
    }
    return handle;
  }

  WorkshopTaskInferenceResult? get _currentInferenceResult =>
      _currentHandle == null ? null : widget.executionController.state.result;

  bool get _hasVerifiedArtifact {
    final result = _buildResult;
    return result != null &&
        _repairPreparer.planner.assess(result).isVerifiedSuccess;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        top: false,
        left: false,
        right: false,
        child: WorkshopConversationSelection(
          child: WorkshopDashboardPage(
            dashboardController: widget.bundle.dashboardController,
            chatController: widget.chatController,
            closeProjectForNewConversation: _closeProjectForNewConversation,
            modelAssignments: widget.modelAssignments,
          ),
        ),
      ),
      bottomNavigationBar: _buildProductionControls(context),
    );
  }

  Widget _buildProductionControls(BuildContext context) {
    final execution = widget.executionController.state;
    final activeTaskId = _activeTaskId;
    final hasPreparedTask = activeTaskId != null && activeTaskId.isNotEmpty;
    final handle = _currentHandle;
    final result = _currentInferenceResult;

    if (!hasPreparedTask && !_projectReadyForBuild && _buildResult == null) {
      return const SizedBox.shrink();
    }

    final lifecycleError = execution.error;
    final shownError = _error ??
        (lifecycleError == null ? null : 'Esecuzione non riuscita: $lifecycleError');

    return SafeArea(
      top: false,
      child: Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (shownError != null) ...<Widget>[
                Text(shownError,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 8),
              ],
              if (_hasVerifiedArtifact) ...<Widget>[
                Text('Artifact pronto: ${_buildResult!.artifactPath}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 8),
              ],
              if (_mutationBusy)
                const FilledButton(onPressed: null, child: Text('Cantiere in esecuzione…'))
              else if (execution.isRunning)
                FilledButton.icon(
                  onPressed: execution.status ==
                          WorkshopProductionExecutionStatus.cancelling
                      ? null
                      : widget.executionController.cancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(execution.status ==
                          WorkshopProductionExecutionStatus.cancelling
                      ? 'Annullamento in corso…'
                      : 'Annulla esecuzione'),
                )
              else if (handle != null && result?.readyForApproval == true)
                FilledButton.icon(
                  onPressed: _reviewChanges,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Rivedi, approva e continua'),
                )
              else if (hasPreparedTask && execution.canRetry)
                FilledButton.icon(
                  onPressed: () => _runPreparedTask(retry: true),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Riprova task'),
                )
              else if (hasPreparedTask &&
                  execution.status == WorkshopProductionExecutionStatus.idle)
                FilledButton.icon(
                  onPressed: _runPreparedTask,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Esegui task'),
                )
              else if (_projectReadyForBuild && _buildResult == null)
                FilledButton.icon(
                  onPressed: _buildCompletedProject,
                  icon: const Icon(Icons.android),
                  label: const Text('Genera APK finale'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum WorkshopProductionUiAction { run, review, apply, build, none }

final class WorkshopProductionActionState {
  const WorkshopProductionActionState({
    required this.action,
    required this.label,
    required this.icon,
    required this.enabled,
  });

  final WorkshopProductionUiAction action;
  final String label;
  final IconData icon;
  final bool enabled;

  static WorkshopProductionActionState resolve({
    required bool hasPreparedTask,
    required bool hasBoundHandle,
    required bool inferenceReadyForApproval,
    required WorkspaceSessionStatus? sessionStatus,
    required bool projectReadyForBuild,
    required bool isBusy,
  }) {
    if (isBusy) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.none,
        label: 'Cantiere in esecuzione…',
        icon: Icons.hourglass_top,
        enabled: false,
      );
    }
    if (!hasPreparedTask && projectReadyForBuild) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.build,
        label: 'Genera APK finale',
        icon: Icons.android,
        enabled: true,
      );
    }
    if (!hasPreparedTask) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.none,
        label: 'Nessun task preparato',
        icon: Icons.info_outline,
        enabled: false,
      );
    }
    if (!hasBoundHandle) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.run,
        label: 'Esegui task',
        icon: Icons.play_arrow,
        enabled: true,
      );
    }
    if (sessionStatus == WorkspaceSessionStatus.approved) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.apply,
        label: 'Applica modifiche approvate',
        icon: Icons.done_all,
        enabled: true,
      );
    }
    if (sessionStatus == WorkspaceSessionStatus.completed) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.none,
        label: 'Task completato',
        icon: Icons.check_circle_outline,
        enabled: false,
      );
    }
    if (sessionStatus == WorkspaceSessionStatus.blocked ||
        sessionStatus == WorkspaceSessionStatus.cancelled) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.none,
        label: 'Task bloccato',
        icon: Icons.block,
        enabled: false,
      );
    }
    if (inferenceReadyForApproval &&
        sessionStatus == WorkspaceSessionStatus.validation) {
      return const WorkshopProductionActionState(
        action: WorkshopProductionUiAction.review,
        label: 'Rivedi e decidi',
        icon: Icons.fact_check_outlined,
        enabled: true,
      );
    }
    return const WorkshopProductionActionState(
      action: WorkshopProductionUiAction.none,
      label: 'Task non pronto per approvazione',
      icon: Icons.pending_outlined,
      enabled: false,
    );
  }
}
