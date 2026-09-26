import 'package:flutter/foundation.dart';
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
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_recovery_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/native/platform/android_intent_handler.dart';

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
    this.recoveryCoordinator,
    AndroidIntentHandler? androidIntentHandler,
  }) : _androidIntentHandler = androidIntentHandler;

  final WorkshopProductionLifecycleBundle bundle;
  final List<WorkshopModelAssignment> modelAssignments;
  final WorkshopProductionExecutionController executionController;
  final WorkshopChatController chatController;
  final WorkshopProductionRecoveryCoordinator? recoveryCoordinator;
  final AndroidIntentHandler? _androidIntentHandler;

  @override
  State<WorkshopProductionDashboardPage> createState() =>
      _WorkshopProductionDashboardPageState();
}

class _WorkshopProductionDashboardPageState
    extends State<WorkshopProductionDashboardPage> {
  late final WorkshopProductionTaskCoordinator _coordinator;
  late final WorkshopBuildRepairPreparer _repairPreparer;
  late final AndroidIntentHandler _androidIntentHandler;
  WorkshopBuildResult? _buildResult;
  bool _mutationBusy = false;
  bool _autoAdvanceScheduled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _coordinator = WorkshopProductionTaskCoordinator(bundle: widget.bundle);
    _repairPreparer = WorkshopBuildRepairPreparer(bundle: widget.bundle);
    _androidIntentHandler =
        widget._androidIntentHandler ?? AndroidIntentHandler();
    _buildResult = widget.bundle.dashboardController.state.lastBuildResult;
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
    setState(() {
      _buildResult =
          widget.bundle.dashboardController.state.lastBuildResult;
    });
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
    final dashboard = widget.bundle.dashboardController.state;
    var execution = widget.executionController.state;
    if (_mutationBusy || execution.isRunning || dashboard.isBusy) return;
    final taskId = _activeTaskId;

    if (taskId != null && taskId.isNotEmpty) {
      if (WorkshopProductionExecutionAffinity.isStaleForProject(
        projectId: dashboard.projectId,
        executionProjectId: execution.handle?.plan.id,
        executionStatus: execution.status,
        executionIsRunning: execution.isRunning,
      )) {
        await widget.executionController.abandonCurrentExecution();
        if (widget.executionController.state.status !=
            WorkshopProductionExecutionStatus.idle) {
          widget.executionController.reset();
        }
        execution = widget.executionController.state;
      }

      if (execution.status == WorkshopProductionExecutionStatus.idle) {
        await _runPreparedTask();
      } else if (WorkshopProductionAutonomyPolicy.canAutoApply(
        projectApproved: _projectApprovalAuthorizesCurrentProject,
        executionStatus: execution.status,
        inferenceReadyForApproval:
            _currentInferenceResult?.readyForApproval == true,
        sessionStatus: _currentHandle?.session.status,
      )) {
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
        final rawSummary = result.review.approved
            ? result.validation?.summary.trim()
            : result.review.summary.trim();
        final summary = rawSummary == null || rawSummary.isEmpty
            ? null
            : rawSummary.length <= 240
                ? rawSummary
                : '${rawSummary.substring(0, 240)}…';
        setState(() {
          _error = summary == null
              ? 'Il task è stato elaborato ma non ha superato la revisione.'
              : 'Il task non ha superato i gate: $summary';
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
      await widget.executionController.parkCurrentExecution();

      final dashboardController = widget.bundle.dashboardController;
      final recovery = widget.recoveryCoordinator;
      if (recovery != null && dashboardController.state.hasProject) {
        // "Nuova conversazione" parks the project; it does not destroy it.
        await recovery.saveCurrent(dashboardController);
      }

      // A new conversation must not inherit execution mode or terminal UI
      // state from the parked project. Its durable execution remains in the
      // store and will restore its own mode if explicitly reopened later.
      widget.executionController.reset();

      dashboardController.forgetProduction();
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
          _error = 'Parcheggio del progetto non riuscito: $error';
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
      }
    }
  }

  Future<void> _openSavedProjects() async {
    final recovery = widget.recoveryCoordinator;
    if (recovery == null || _mutationBusy) {
      return;
    }

    final projects = await recovery.listSavedProjects();
    if (!mounted) {
      return;
    }

    if (projects.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Non ci sono progetti salvati.')),
        );
      return;
    }

    final selectedProjectId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: projects.length + 1,
            separatorBuilder: (_, index) =>
                index == 0 ? const Divider() : const SizedBox(height: 4),
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Progetti',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  subtitle: const Text(
                    'Scegli un progetto salvato da riprendere nel Cantiere.',
                  ),
                );
              }

              final project = projects[index - 1];
              final percent = (project.progress * 100).round();
              final updated = project.updatedAt.toLocal();
              final updatedLabel =
                  '${updated.day.toString().padLeft(2, '0')}/'
                  '${updated.month.toString().padLeft(2, '0')}/'
                  '${updated.year} '
                  '${updated.hour.toString().padLeft(2, '0')}:'
                  '${updated.minute.toString().padLeft(2, '0')}';

              return Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: Text(
                    project.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${project.status.name} · $percent% · $updatedLabel',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(project.projectId),
                ),
              );
            },
          ),
        );
      },
    );

    if (selectedProjectId == null || !mounted) {
      return;
    }

    final dashboardController = widget.bundle.dashboardController;
    final currentProjectId = dashboardController.state.projectId?.trim();
    if (currentProjectId == selectedProjectId) {
      return;
    }

    if (dashboardController.state.hasProject) {
      final parked = await _closeProjectForNewConversation();
      if (!parked || !mounted) {
        return;
      }
    }

    setState(() {
      _mutationBusy = true;
      _error = null;
    });

    try {
      final restored = await recovery.restoreProject(
        dashboardController,
        projectId: selectedProjectId,
      );
      if (!restored) {
        throw StateError('Il progetto selezionato non è più disponibile.');
      }

      final recoveredTaskId = dashboardController.state.activeTaskId?.trim();
      if (recoveredTaskId != null && recoveredTaskId.isNotEmpty) {
        await widget.executionController
            .restorePersistentExecutionForPreparedTask();
      }

      widget.chatController
        ..clearConversation()
        ..addSystemMessage(
          'Progetto “${dashboardController.state.projectTitle ?? selectedProjectId}” '
          'recuperato dal menu Progetti.',
        );

      if (!mounted) {
        return;
      }

      setState(() {
        _buildResult = dashboardController.state.lastBuildResult;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Recupero del progetto non riuscito: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
        _scheduleAutoAdvance();
      }
    }
  }

  Future<void> _retryFinalBuildOnly() async {
    final result = _buildResult;
    if (_mutationBusy ||
        !_projectReadyForBuild ||
        result == null ||
        _repairPreparer.planner.assess(result).isVerifiedSuccess) {
      return;
    }

    setState(() {
      _buildResult = null;
      _error = null;
    });

    await _buildCompletedProject();
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
        final sourceApproval =
            widget.bundle.dashboardController.state.projectApproval;
        final inheritsProjectAuthorization =
            sourceApproval != null && sourceApproval.projectId == failedPlan.id;

        await _repairPreparer.prepare(
          failedPlan: failedPlan,
          failedBuild: result,
          repairNumber: repairNumber,
        );
        if (!mounted) return;

        // A bounded repair is a continuation of the product the owner already
        // authorized, not a new product request. Preserve that authorization
        // only when the failed project itself carried valid project-scoped
        // approval. The repair project still receives a distinct approval id
        // and must pass Engineer -> Reviewer -> validation -> guarded apply.
        if (inheritsProjectAuthorization) {
          widget.bundle.dashboardController.approveCurrentProject(
            approvedBy: sourceApproval.approvedBy,
            derivedFromApprovalId: sourceApproval.approvalId,
          );
        }

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

  Future<void> _installVerifiedArtifact() async {
    final artifactPath = _buildResult?.artifactPath?.trim();
    if (!_hasVerifiedArtifact ||
        artifactPath == null ||
        artifactPath.isEmpty ||
        _mutationBusy) {
      return;
    }

    setState(() {
      _mutationBusy = true;
      _error = null;
    });

    try {
      final verification = await _androidIntentHandler.verifyApk(artifactPath);
      final verificationError = verification.fold<String?>(
        (failure) => failure.toString(),
        (details) {
          if (details['valid'] == true) {
            return null;
          }
          final reason = details['reason']?.toString().trim();
          return reason == null || reason.isEmpty
              ? 'APK generato non valido.'
              : 'APK generato non valido: $reason';
        },
      );

      if (verificationError != null) {
        if (mounted) {
          setState(() => _error = verificationError);
        }
        return;
      }

      final opened = await _androidIntentHandler.openApkInstaller(artifactPath);
      final installError = opened.fold<String?>(
        (failure) => failure.toString(),
        (didOpen) => didOpen
            ? null
            : 'Android non ha aperto il programma di installazione.',
      );

      if (installError != null && mounted) {
        setState(() => _error = installError);
      }
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
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

  bool get _hasFailedFinalBuild {
    final result = _buildResult;
    return result != null &&
        !_repairPreparer.planner.assess(result).isVerifiedSuccess;
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
            openProjects: _openSavedProjects,
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
                Text('APK verificato pronto: ${_buildResult!.artifactPath}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 8),
                if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.android)
                  OutlinedButton.icon(
                    onPressed:
                        _mutationBusy ? null : _installVerifiedArtifact,
                    icon: const Icon(Icons.install_mobile_outlined),
                    label: const Text('Installa APK'),
                  ),
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
              else if (_projectReadyForBuild && _hasFailedFinalBuild)
                FilledButton.icon(
                  onPressed: _retryFinalBuildOnly,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Riprova solo build'),
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

/// Pure guard for project-authorized autonomous continuation.
///
/// This predicate never mutates state. It intentionally requires all four
/// independent facts before the UI can record a task-level approval:
/// project owner authorization, successful execution, Reviewer/validation
/// readiness and a WorkspaceSession still parked at the validation boundary.
/// Guards the boundary between a freshly prepared project and the long-lived
/// execution controller owned above the Cantiere route.
///
/// A terminal execution from another project is stale UI/runtime state and must
/// never turn a new approved project into a "Riprova task" action. A terminal
/// execution belonging to the same project remains retryable and is preserved.
abstract final class WorkshopProductionExecutionAffinity {
  static bool isStaleForProject({
    required String? projectId,
    required String? executionProjectId,
    required WorkshopProductionExecutionStatus executionStatus,
    required bool executionIsRunning,
  }) {
    final normalizedProjectId = projectId?.trim();
    final normalizedExecutionProjectId = executionProjectId?.trim();

    if (normalizedProjectId == null ||
        normalizedProjectId.isEmpty ||
        normalizedExecutionProjectId == null ||
        normalizedExecutionProjectId.isEmpty) {
      return false;
    }

    if (executionIsRunning ||
        executionStatus == WorkshopProductionExecutionStatus.idle) {
      return false;
    }

    return normalizedExecutionProjectId != normalizedProjectId;
  }
}

abstract final class WorkshopProductionAutonomyPolicy {
  static bool canAutoApply({
    required bool projectApproved,
    required WorkshopProductionExecutionStatus executionStatus,
    required bool inferenceReadyForApproval,
    required WorkspaceSessionStatus? sessionStatus,
  }) {
    return projectApproved &&
        executionStatus == WorkshopProductionExecutionStatus.succeeded &&
        inferenceReadyForApproval &&
        sessionStatus == WorkspaceSessionStatus.validation;
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
