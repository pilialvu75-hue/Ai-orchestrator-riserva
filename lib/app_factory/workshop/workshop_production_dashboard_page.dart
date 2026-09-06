import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Owner-facing production shell for the conversational Cantiere.
///
/// The existing [WorkshopDashboardPage] remains responsible for the Workshop
/// conversation and project preparation. This shell only exposes the guarded
/// production actions for the exact task prepared by that dashboard:
///
/// 1. run Engineer -> Reviewer -> Reviewer against VirtualWorkspace;
/// 2. inspect the staged diff and explicit Reviewer verdicts;
/// 3. explicitly approve or reject the staged changes;
/// 4. explicitly apply an already-approved task.
///
/// No action is automatic and no Assistant configuration, model selection,
/// memory or conversation state is consulted.
final class WorkshopProductionDashboardPage extends StatefulWidget {
  const WorkshopProductionDashboardPage({
    super.key,
    required this.bundle,
    required this.modelAssignments,
  });

  final WorkshopProductionLifecycleBundle bundle;
  final List<WorkshopModelAssignment> modelAssignments;

  @override
  State<WorkshopProductionDashboardPage> createState() =>
      _WorkshopProductionDashboardPageState();
}

class _WorkshopProductionDashboardPageState
    extends State<WorkshopProductionDashboardPage> {
  late final WorkshopProductionTaskCoordinator _coordinator;

  WorkshopProductionTaskHandle? _handle;
  WorkshopTaskInferenceResult? _inferenceResult;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _coordinator = WorkshopProductionTaskCoordinator(
      bundle: widget.bundle,
    );
  }

  Future<void> _runPreparedTask() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final handle = _coordinator.preparedHandle();
      final result = await _coordinator.runPrepared(
        handle: handle,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _handle = handle;
        _inferenceResult = result;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = 'Esecuzione del task non riuscita: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _reviewChanges() async {
    final handle = _currentHandle;
    final result = _currentInferenceResult;

    if (handle == null || result == null || !result.readyForApproval) {
      return;
    }

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
                  Text(
                    'Validazione: ${validation?.summary ?? 'non disponibile'}',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'File modificati (${files.length})',
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (files.isEmpty)
                    const Text('Nessuna modifica staged.')
                  else
                    ...files.map(
                      (file) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${file.changeType.name}: ${file.path}',
                        ),
                      ),
                    ),
                  if (result.review.findings.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'Osservazioni Reviewer',
                      style: Theme.of(dialogContext).textTheme.titleSmall,
                    ),
                    ...result.review.findings.map(Text.new),
                  ],
                  if (result.review.warnings.isNotEmpty ||
                      (validation?.warnings.isNotEmpty ?? false)) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'Avvisi',
                      style: Theme.of(dialogContext).textTheme.titleSmall,
                    ),
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
              onPressed: () => Navigator.of(dialogContext).pop(
                WorkshopApplyDecision.reject,
              ),
              child: const Text('Rifiuta'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                WorkshopApplyDecision.approve,
              ),
              child: const Text('Approva'),
            ),
          ],
        );
      },
    );

    if (decision == null || !mounted) {
      return;
    }

    try {
      _coordinator.decide(
        handle: handle,
        decision: decision,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _error = decision == WorkshopApplyDecision.reject
            ? 'Modifiche rifiutate dal proprietario.'
            : null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = 'Decisione sulle modifiche non riuscita: $error';
      });
    }
  }

  Future<void> _applyApprovedTask() async {
    final handle = _currentHandle;

    if (_busy ||
        handle == null ||
        handle.session.status != WorkspaceSessionStatus.approved ||
        !handle.session.isApplyApproved) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await _coordinator.applyApproved(
        handle: handle,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = 'Applicazione delle modifiche non riuscita: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String? get _activeTaskId =>
      widget.bundle.dashboardController.state.activeTaskId?.trim();

  WorkshopProductionTaskHandle? get _currentHandle {
    final handle = _handle;
    final activeTaskId = _activeTaskId;

    if (handle == null ||
        activeTaskId == null ||
        activeTaskId.isEmpty ||
        handle.taskId != activeTaskId) {
      return null;
    }

    return handle;
  }

  WorkshopTaskInferenceResult? get _currentInferenceResult =>
      _currentHandle == null ? null : _inferenceResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WorkshopDashboardPage(
        dashboardController: widget.bundle.dashboardController,
        modelAssignments: widget.modelAssignments,
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: widget.bundle.dashboardController,
        builder: (context, child) => _buildProductionControls(context),
      ),
    );
  }

  Widget _buildProductionControls(BuildContext context) {
    final activeTaskId = _activeTaskId;

    if (activeTaskId == null || activeTaskId.isEmpty) {
      return const SizedBox.shrink();
    }

    final handle = _currentHandle;
    final result = _currentInferenceResult;
    final status = handle?.session.status;

    final actionState = WorkshopProductionActionState.resolve(
      hasPreparedTask: true,
      hasBoundHandle: handle != null,
      inferenceReadyForApproval: result?.readyForApproval ?? false,
      sessionStatus: status,
      isBusy: _busy,
    );

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
              if (_error != null) ...<Widget>[
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                'Task: $activeTaskId',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: actionState.enabled
                    ? switch (actionState.action) {
                        WorkshopProductionUiAction.run => _runPreparedTask,
                        WorkshopProductionUiAction.review => _reviewChanges,
                        WorkshopProductionUiAction.apply => _applyApprovedTask,
                        WorkshopProductionUiAction.none => null,
                      }
                    : null,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(actionState.icon),
                label: Text(actionState.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum WorkshopProductionUiAction {
  run,
  review,
  apply,
  none,
}

/// Pure mapping used by the production shell to keep the explicit owner gates
/// visible and testable independently from the conversational page.
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
