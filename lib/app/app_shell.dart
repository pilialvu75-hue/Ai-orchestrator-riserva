import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/features/chat/presentation/pages/chat_page.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/settings_page.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_assignments.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_dashboard_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_recovery_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_validated_proposal_snapshot.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final UpdateManager _updateManager;
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  String? _shownUpdateVersion;
  bool _openingWorkshop = false;
  WorkshopProductionLifecycleBundle? _workshopBundle;
  WorkshopProductionRecoveryCoordinator? _workshopRecoveryCoordinator;
  WorkshopProductionExecutionController? _workshopExecutionController;
  WorkshopChatController? _workshopChatController;
  List<WorkshopModelAssignment>? _workshopAssignments;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateManager = di.sl<UpdateManager>();
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _updateManager.state.addListener(_onUpdateStateChanged);
    unawaited(_updateManager.startBackgroundChecks(
      interval: AppConstants.updateCheckInterval,
    ));
    unawaited(_runtimeDiagnostics.validateOnStartup());
  }

  void _onUpdateStateChanged() {
    final currentState = _updateManager.state.value;
    final latest = currentState.latestManifest;
    if (!mounted || latest == null) return;
    final canOfferUpdate =
        currentState.status == UpdateStatus.updateAvailable ||
        currentState.status == UpdateStatus.readyToInstall;
    if (canOfferUpdate && _shownUpdateVersion != latest.version) {
      _shownUpdateVersion = latest.version;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpdateDialog(latest);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_flushWorkshopCheckpoint());
    }
  }

  Future<void> _flushWorkshopCheckpoint() async {
    final recovery = _workshopRecoveryCoordinator;
    final bundle = _workshopBundle;
    if (recovery == null || bundle == null) return;

    try {
      await recovery.saveCurrent(bundle.dashboardController);
    } catch (error) {
      debugPrint('Workshop checkpoint flush failed: $error');
    }
  }

  Future<void> _parkAndDisposeWorkshopSession() async {
    final execution = _workshopExecutionController;
    final recovery = _workshopRecoveryCoordinator;
    final bundle = _workshopBundle;

    try {
      if (execution != null) {
        await execution.cancelAndWait();
        await execution.abandonCurrentExecution();
      }

      if (recovery != null &&
          bundle != null &&
          bundle.dashboardController.state.hasProject) {
        await recovery.saveCurrent(bundle.dashboardController);
      }
    } catch (error) {
      debugPrint('Workshop project parking failed: $error');
    } finally {
      await _disposeWorkshopSession();
    }
  }

  Future<void> _disposeWorkshopSession() async {
    final execution = _workshopExecutionController;
    final chat = _workshopChatController;
    final recovery = _workshopRecoveryCoordinator;
    final bundle = _workshopBundle;

    _workshopExecutionController = null;
    _workshopChatController = null;
    _workshopRecoveryCoordinator = null;
    _workshopBundle = null;
    _workshopAssignments = null;

    execution?.dispose();
    chat?.dispose();
    if (recovery != null) {
      try {
        await recovery.detach();
      } catch (error) {
        debugPrint('Workshop recovery detach failed: $error');
      }
    }
    bundle?.dashboardController.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateManager.state.removeListener(_onUpdateStateChanged);
    unawaited(_disposeWorkshopSession());
    super.dispose();
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BlocProvider.value(
        value: context.read<ModelDownloadBloc>(),
        child: const SettingsPage(),
      ),
    ));
  }

  Future<void> _ensureWorkshopSession() async {
    if (_workshopBundle != null &&
        _workshopRecoveryCoordinator != null &&
        _workshopExecutionController != null &&
        _workshopChatController != null &&
        _workshopAssignments != null) {
      return;
    }

    final applicationDirectory = await getApplicationDocumentsDirectory();
    final workspaceRootPath = p.join(
      applicationDirectory.path,
      'ai_orchestrator_workshop',
    );
    final workspaceDirectory = Directory(workspaceRootPath);
    await workspaceDirectory.create(recursive: true);
    final recoverySnapshotsRootPath = p.join(
      applicationDirectory.path,
      'ai_orchestrator_workshop_recovery',
      'validated_proposals',
    );
    final workshopAssignments = await WorkshopFactory.loadPersistedAssignments();

    final bundle = await WorkshopProductionLifecycleBundleFactory
        .createForWorkspaceWithPersistedReuse(
      workspaceRootPath: workspaceDirectory.path,
      preferences: di.sl<PreferencesService>(),
      assignments: workshopAssignments,
    );
    final recovery = WorkshopProductionRecoveryCoordinator(
      checkpointStore: PersistentWorkshopCheckpointStore(
        preferences: di.sl<PreferencesService>(),
      ),
    );

    try {
      // Cantiere entry is intentionally neutral. Durable projects remain in
      // recovery storage until the owner explicitly selects one from Progetti.
      if (!mounted) {
        bundle.dashboardController.dispose();
        return;
      }

      recovery.attach(bundle.dashboardController);
      final taskCoordinator = WorkshopProductionTaskCoordinator(bundle: bundle);
      final executionStore = WorkshopExecutionStore(
        preferences: di.sl<PreferencesService>(),
      );
      final execution = WorkshopProductionExecutionController(
        runner: WorkshopProductionTaskExecutionRunner(
          coordinator: taskCoordinator,
        ),
        executionStore: executionStore,
        validatedProposalSnapshotService:
            WorkshopValidatedProposalSnapshotService(
          snapshotsRootPath: recoverySnapshotsRootPath,
        ),
      );

      final chat = WorkshopChatController(
        inferenceGateway: WorkshopFactory.createInferenceGateway(
          assignments: workshopAssignments,
        ),
        sessionId:
            'workshop-chat:${DateTime.now().microsecondsSinceEpoch}',
      );

      _workshopBundle = bundle;
      _workshopRecoveryCoordinator = recovery;
      _workshopExecutionController = execution;
      _workshopChatController = chat;
      _workshopAssignments = workshopAssignments;
    } catch (_) {
      await recovery.detach(flushCurrent: false);
      bundle.dashboardController.dispose();
      rethrow;
    }
  }

  Future<void> _openWorkshop(BuildContext context) async {
    if (_openingWorkshop) return;
    setState(() => _openingWorkshop = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      await _ensureWorkshopSession();
      if (!mounted) return;

      final workshopBundle = _workshopBundle;
      final workshopAssignments = _workshopAssignments;
      final executionController = _workshopExecutionController;
      final chatController = _workshopChatController;
      if (workshopBundle == null ||
          workshopAssignments == null ||
          executionController == null ||
          chatController == null) {
        throw StateError('Il lifecycle persistente del Cantiere non è disponibile.');
      }

      await navigator.push(MaterialPageRoute<void>(
        builder: (_) => SafeArea(
          top: false,
          left: false,
          right: false,
          maintainBottomViewPadding: true,
          minimum: const EdgeInsets.only(bottom: 12),
          child: WorkshopProductionDashboardPage(
            bundle: workshopBundle,
            modelAssignments: workshopAssignments,
            executionController: executionController,
            chatController: chatController,
            recoveryCoordinator: _workshopRecoveryCoordinator,
          ),
        ),
      ));
      // Leaving the Cantiere parks the project instead of keeping its runtime
      // attached to the next route opening. Reopening therefore starts clean.
      await _parkAndDisposeWorkshopSession();
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Impossibile aprire il Cantiere: $error')),
        );
    } finally {
      if (mounted) setState(() => _openingWorkshop = false);
    }
  }

  Future<void> _startUpdateFromDialog() async {
    final state = _updateManager.state.value;
    final readyToInstall = state.status == UpdateStatus.readyToInstall;
    final ok = readyToInstall ? true : await _updateManager.downloadLatestApk();
    if (!ok || !mounted) {
      if (mounted) {
        final message = _updateManager.state.value.errorMessage ??
            context.l10n.t('force_update_failed');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    final installerStarted = await _updateManager.prepareInstallIntent();
    unawaited(_updateManager.refreshDiagnostics());
    if (!installerStarted && mounted) {
      final message = _updateManager.state.value.errorMessage ??
          context.l10n.t('force_update_failed');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showUpdateDialog(UpdateManifest manifest) async {
    if (!mounted) return;
    final l10n = context.l10n;
    final currentVersion = _updateManager.currentVersion;
    final preview = manifest.changelog.trim().isEmpty
        ? 'No changelog available.'
        : manifest.changelog.trim().split('\n').take(4).join('\n');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${l10n.t('update_available')}: ${manifest.version}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${l10n.t('current_version')}: $currentVersion'),
              const SizedBox(height: 12),
              Text(preview),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.t('later')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(_startUpdateFromDialog());
            },
            child: Text(l10n.t('update')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Orchestrator')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Assistente', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ChatPage()),
                );
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Apri Assistente'),
            ),
            const SizedBox(height: 24),
            Text('Cantiere', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openingWorkshop ? null : () => _openWorkshop(context),
              icon: _openingWorkshop
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.construction),
              label: Text(
                _openingWorkshop ? 'Apertura Cantiere...' : 'Apri Cantiere',
              ),
            ),
            const SizedBox(height: 24),
            Text('Impostazioni',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openSettings(context),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Apri Impostazioni'),
            ),
          ],
        ),
      ),
    );
  }
}
