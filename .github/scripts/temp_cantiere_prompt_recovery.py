from pathlib import Path


def replace_one(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: anchor count {count}, expected 1\nANCHOR:\n{old}"
        )
    file.write_text(text.replace(old, new, 1))


recovery = "lib/app_factory/workshop/workshop_production_recovery_coordinator.dart"
replace_one(
    recovery,
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';\n"
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';\n",
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';\n"
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_pending_prompt_draft.dart';\n"
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';\n",
)
replace_one(
    recovery,
    "  static const String _projectJobPrefix = 'workshop-production:project:v2:';\n"
    "  static const String _payloadPrefix = 'workshop-production-state-v1:';\n",
    "  static const String _projectJobPrefix = 'workshop-production:project:v2:';\n"
    "  static const String _payloadPrefix = 'workshop-production-state-v1:';\n"
    "  static const String _draftJobId = 'workshop-production:draft:v1';\n"
    "  static const String _draftPayloadPrefix = 'workshop-production-draft-v1:';\n",
)
replace_one(
    recovery,
    "  Future<void> clear() async {\n",
    """  Future<void> savePendingPrompt({
    required String instruction,
    required String title,
  }) async {
    final normalizedInstruction = instruction.trim();
    final normalizedTitle = title.trim();
    if (normalizedInstruction.isEmpty || normalizedTitle.isEmpty) {
      throw ArgumentError(
        'Workshop pending prompt requires instruction and title.',
      );
    }

    final updatedAt = DateTime.now().toUtc();
    await _runSerializedPersistence(
      () => _checkpointStore.save(
        WorkshopBackgroundCheckpoint(
          jobId: _draftJobId,
          requestId: 'draft:${updatedAt.microsecondsSinceEpoch}',
          status: WorkshopBackgroundStatus.paused,
          updatedAt: updatedAt,
          message: '$_draftPayloadPrefix${jsonEncode(<String, Object?>{
            'instruction': normalizedInstruction,
            'title': normalizedTitle,
          })}',
        ),
      ),
    );
  }

  Future<WorkshopPendingPromptDraft?> loadPendingPrompt() async {
    final checkpoint = await _checkpointStore.load(_draftJobId);
    final raw = checkpoint?.message?.trim();
    if (checkpoint == null ||
        raw == null ||
        !raw.startsWith(_draftPayloadPrefix)) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw.substring(_draftPayloadPrefix.length));
      if (decoded is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      final instruction = map['instruction']?.toString().trim() ?? '';
      final title = map['title']?.toString().trim() ?? '';
      if (instruction.isEmpty || title.isEmpty) {
        return null;
      }
      return WorkshopPendingPromptDraft(
        instruction: instruction,
        title: title,
        updatedAt: checkpoint.updatedAt.toUtc(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPendingPrompt() =>
      _runSerializedPersistence(() => _checkpointStore.remove(_draftJobId));

  Future<void> clear() async {
""",
)
replace_one(
    recovery,
    "        if (_isProductionCheckpoint(checkpoint.jobId)) {\n"
    "          await _checkpointStore.remove(checkpoint.jobId);\n"
    "        }\n",
    "        if (_isProductionCheckpoint(checkpoint.jobId) ||\n"
    "            checkpoint.jobId == _draftJobId) {\n"
    "          await _checkpointStore.remove(checkpoint.jobId);\n"
    "        }\n",
)

dashboard = "lib/app_factory/workshop/workshop_dashboard_page.dart"
replace_one(
    dashboard,
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';\n",
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';\n"
    "import 'package:ai_orchestrator/app_factory/workshop/workshop_pending_prompt_draft.dart';\n",
)
replace_one(
    dashboard,
    "    Future<bool> Function()? closeProjectForNewConversation,\n"
    "    Future<void> Function()? openProjects,\n"
    "    List<WorkshopModelAssignment>? modelAssignments,\n",
    "    Future<bool> Function()? closeProjectForNewConversation,\n"
    "    Future<void> Function()? openProjects,\n"
    "    Future<void> Function(String instruction, String title)? savePendingPrompt,\n"
    "    Future<WorkshopPendingPromptDraft?> Function()? loadPendingPrompt,\n"
    "    Future<void> Function()? clearPendingPrompt,\n"
    "    Future<void> Function()? persistCurrentProject,\n"
    "    List<WorkshopModelAssignment>? modelAssignments,\n",
)
replace_one(
    dashboard,
    "        _closeProjectForNewConversation = closeProjectForNewConversation,\n"
    "        _openProjects = openProjects,\n"
    "        _modelAssignments =\n",
    "        _closeProjectForNewConversation = closeProjectForNewConversation,\n"
    "        _openProjects = openProjects,\n"
    "        _savePendingPrompt = savePendingPrompt,\n"
    "        _loadPendingPrompt = loadPendingPrompt,\n"
    "        _clearPendingPrompt = clearPendingPrompt,\n"
    "        _persistCurrentProject = persistCurrentProject,\n"
    "        _modelAssignments =\n",
)
replace_one(
    dashboard,
    "  final Future<bool> Function()? _closeProjectForNewConversation;\n"
    "  final Future<void> Function()? _openProjects;\n\n",
    "  final Future<bool> Function()? _closeProjectForNewConversation;\n"
    "  final Future<void> Function()? _openProjects;\n"
    "  final Future<void> Function(String instruction, String title)? _savePendingPrompt;\n"
    "  final Future<WorkshopPendingPromptDraft?> Function()? _loadPendingPrompt;\n"
    "  final Future<void> Function()? _clearPendingPrompt;\n"
    "  final Future<void> Function()? _persistCurrentProject;\n\n",
)
replace_one(
    dashboard,
    "          _addWelcomeMessage();\n",
    "          _addWelcomeMessage();\n"
    "          _restorePendingPromptDraft();\n",
)
replace_one(
    dashboard,
    "  Future<void> _sendMessage() async {\n",
    """  Future<void> _restorePendingPromptDraft() async {
    final load = widget._loadPendingPrompt;
    if (load == null || _dashboardController?.state.hasProject == true) {
      return;
    }

    try {
      final draft = await load();
      if (!mounted ||
          draft == null ||
          _dashboardController?.state.hasProject == true) {
        return;
      }
      final instruction = draft.instruction.trim();
      final title = draft.title.trim();
      if (instruction.isEmpty || title.isEmpty) {
        return;
      }

      setState(() {
        _pendingConfirmation = false;
        _pendingInstruction = instruction;
        _pendingTitle = title;
        _pendingApprovedProposal = null;
        if (_messageController.text.trim().isEmpty) {
          _messageController.text = instruction;
          _messageController.selection = TextSelection.collapsed(
            offset: _messageController.text.length,
          );
        }
      });
      _chatController.addSystemMessage(
        'Bozza recuperata dopo l’interruzione. Premi invia per riprovare.',
        excludeFromContext: true,
      );
    } catch (error) {
      if (mounted) {
        _showError('Recupero della bozza non riuscito: $error');
      }
    }
  }

  Future<void> _sendMessage() async {
""",
)
replace_one(
    dashboard,
    "    _pendingApprovedProposal = null;\n\n"
    "    _messageController.clear();\n\n"
    "    final result =\n",
    """    _pendingApprovedProposal = null;

    final savePendingPrompt = widget._savePendingPrompt;
    if (savePendingPrompt != null) {
      try {
        await savePendingPrompt(
          _pendingInstruction!,
          _pendingTitle!,
        );
      } catch (error) {
        if (mounted) {
          _showError(
            'Il prompt non è stato inviato perché la bozza non può essere salvata: $error',
          );
        }
        return;
      }
    }

    _messageController.clear();

    final result =
""",
)
replace_one(
    dashboard,
    "      controller.approveCurrentProject();\n\n"
    "      _chatController.addSystemMessage(\n",
    """      controller.approveCurrentProject();

      final persistCurrentProject = widget._persistCurrentProject;
      if (persistCurrentProject != null) {
        await persistCurrentProject();
        await widget._clearPendingPrompt?.call();
      }

      _chatController.addSystemMessage(
""",
)

production = "lib/app_factory/workshop/workshop_production_dashboard_page.dart"
replace_one(
    production,
    "                  trailing: const Icon(Icons.chevron_right),\n"
    "                  onTap: () =>\n"
    "                      Navigator.of(sheetContext).pop(project.projectId),\n",
    """                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: 'Elimina progetto',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => Navigator.of(sheetContext)
                            .pop('delete:${project.projectId}'),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(project.projectId),
""",
)
replace_one(
    production,
    "    if (selectedProjectId == null || !mounted) {\n"
    "      return;\n"
    "    }\n\n"
    "    final dashboardController = widget.bundle.dashboardController;\n",
    """    if (selectedProjectId == null || !mounted) {
      return;
    }

    const deletePrefix = 'delete:';
    if (selectedProjectId.startsWith(deletePrefix)) {
      final projectId = selectedProjectId.substring(deletePrefix.length);
      WorkshopSavedProjectSummary? selectedProject;
      for (final candidate in projects) {
        if (candidate.projectId == projectId) {
          selectedProject = candidate;
          break;
        }
      }
      if (selectedProject == null) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Elimina progetto'),
          content: Text(
            'Eliminare definitivamente “${selectedProject.title}”? '
            'Il progetto salvato non potrà essere ripreso.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Elimina'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _deleteSavedProject(selectedProject);
      }
      return;
    }

    final dashboardController = widget.bundle.dashboardController;
""",
)
replace_one(
    production,
    "  Future<void> _openSavedProjects() async {\n",
    """  Future<void> _deleteSavedProject(
    WorkshopSavedProjectSummary project,
  ) async {
    final recovery = widget.recoveryCoordinator;
    if (recovery == null || _mutationBusy) {
      return;
    }

    setState(() {
      _mutationBusy = true;
      _error = null;
    });

    try {
      final dashboardController = widget.bundle.dashboardController;
      final activeProjectId = dashboardController.state.projectId?.trim();
      if (activeProjectId == project.projectId) {
        await widget.executionController.cancelAndWait();
        await widget.executionController.abandonCurrentExecution();
        if (widget.executionController.state.status !=
            WorkshopProductionExecutionStatus.idle) {
          widget.executionController.reset();
        }
        dashboardController.forgetProduction();
        widget.executionController.clearBuildRepairChain();
      }

      await recovery.removeProject(project.projectId);
      if (!mounted) {
        return;
      }
      setState(() {
        _buildResult = null;
        _error = null;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Progetto “${project.title}” eliminato.')),
        );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Eliminazione del progetto non riuscita: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _mutationBusy = false);
      }
    }
  }

  Future<void> _openSavedProjects() async {
""",
)
replace_one(
    production,
    "            closeProjectForNewConversation: _closeProjectForNewConversation,\n"
    "            openProjects: _openSavedProjects,\n"
    "            modelAssignments: widget.modelAssignments,\n",
    """            closeProjectForNewConversation: _closeProjectForNewConversation,
            openProjects: _openSavedProjects,
            savePendingPrompt: widget.recoveryCoordinator == null
                ? null
                : (instruction, title) =>
                    widget.recoveryCoordinator!.savePendingPrompt(
                      instruction: instruction,
                      title: title,
                    ),
            loadPendingPrompt: widget.recoveryCoordinator?.loadPendingPrompt,
            clearPendingPrompt: widget.recoveryCoordinator?.clearPendingPrompt,
            persistCurrentProject: widget.recoveryCoordinator == null
                ? null
                : () => widget.recoveryCoordinator!
                    .saveCurrent(widget.bundle.dashboardController),
            modelAssignments: widget.modelAssignments,
""",
)
