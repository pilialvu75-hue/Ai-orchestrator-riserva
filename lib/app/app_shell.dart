import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/features/chat/presentation/pages/chat_page.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/settings_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_dashboard_page.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final UpdateManager _updateManager;
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;

  String? _shownUpdateVersion;
  bool _openingWorkshop = false;

  @override
  void initState() {
    super.initState();

    _updateManager = di.sl<UpdateManager>();
    _runtimeDiagnostics =
        di.sl<LocalRuntimeDiagnosticsService>();

    _updateManager.state.addListener(
      _onUpdateStateChanged,
    );

    unawaited(
      _updateManager.startBackgroundChecks(
        interval: AppConstants.updateCheckInterval,
      ),
    );

    unawaited(
      _runtimeDiagnostics.validateOnStartup(),
    );
  }

  void _onUpdateStateChanged() {
    final currentState =
        _updateManager.state.value;
    final latest =
        currentState.latestManifest;

    if (!mounted || latest == null) {
      return;
    }

    final canOfferUpdate =
        currentState.status == UpdateStatus.updateAvailable ||
        currentState.status == UpdateStatus.readyToInstall;

    if (canOfferUpdate &&
        _shownUpdateVersion != latest.version) {
      _shownUpdateVersion = latest.version;

      WidgetsBinding.instance.addPostFrameCallback(
        (_) {
          if (mounted) {
            _showUpdateDialog(latest);
          }
        },
      );
    }
  }

  @override
  void dispose() {
    _updateManager.state.removeListener(
      _onUpdateStateChanged,
    );
    super.dispose();
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: context.read<ModelDownloadBloc>(),
          child: const SettingsPage(),
        ),
      ),
    );
  }

  Future<void> _openWorkshop(
    BuildContext context,
  ) async {
    if (_openingWorkshop) {
      return;
    }

    setState(() {
      _openingWorkshop = true;
    });

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    WorkshopProductionLifecycleBundle? workshopBundle;

    try {
      final applicationDirectory =
          await getApplicationDocumentsDirectory();

      final workspaceRootPath = p.join(
        applicationDirectory.path,
        'ai_orchestrator_workshop',
      );

      final workspaceDirectory =
          Directory(workspaceRootPath);

      await workspaceDirectory.create(
        recursive: true,
      );

      final workshopAssignments =
          await WorkshopFactory.loadPersistedAssignments();

      workshopBundle =
          WorkshopProductionLifecycleBundleFactory.createForWorkspace(
        workspaceRootPath: workspaceDirectory.path,
        assignments: workshopAssignments,
      );

      if (!mounted) {
        workshopBundle.dashboardController.dispose();
        workshopBundle = null;
        return;
      }

      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => WorkshopProductionDashboardPage(
            bundle: workshopBundle!,
            modelAssignments: workshopAssignments,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        workshopBundle?.dashboardController.dispose();
        return;
      }

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Impossibile aprire il Cantiere: $error',
            ),
          ),
        );
    } finally {
      workshopBundle?.dashboardController.dispose();

      if (mounted) {
        setState(() {
          _openingWorkshop = false;
        });
      }
    }
  }

  Future<void> _startUpdateFromDialog() async {
    final state = _updateManager.state.value;
    final readyToInstall =
        state.status == UpdateStatus.readyToInstall;
    final ok = readyToInstall
        ? true
        : await _updateManager.downloadLatestApk();

    if (!ok || !mounted) {
      if (mounted) {
        final message = _updateManager.state.value.errorMessage ??
            context.l10n.t('force_update_failed');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      return;
    }

    final installerStarted =
        await _updateManager.prepareInstallIntent();
    unawaited(_updateManager.refreshDiagnostics());

    if (!installerStarted && mounted) {
      final message = _updateManager.state.value.errorMessage ??
          context.l10n.t('force_update_failed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _showUpdateDialog(
    UpdateManifest manifest,
  ) async {
    if (!mounted) {
      return;
    }

    final l10n = context.l10n;
    final currentVersion =
        _updateManager.currentVersion;

    final preview =
        manifest.changelog.trim().isEmpty
            ? 'No changelog available.'
            : manifest.changelog
                .trim()
                .split('\n')
                .take(4)
                .join('\n');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            '${l10n.t('update_available')}: '
            '${manifest.version}',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.t('current_version')}: '
                  '$currentVersion',
                ),
                const SizedBox(height: 12),
                Text(preview),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: Text(
                l10n.t('later'),
              ),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_startUpdateFromDialog());
              },
              child: Text(
                l10n.t('update'),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Orchestrator'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Assistente',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChatPage(),
                  ),
                );
              },
              icon: const Icon(
                Icons.chat_bubble_outline,
              ),
              label: const Text(
                'Apri Assistente',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Cantiere',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openingWorkshop
                  ? null
                  : () => _openWorkshop(context),
              icon: _openingWorkshop
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.construction,
                    ),
              label: Text(
                _openingWorkshop
                    ? 'Apertura Cantiere...'
                    : 'Apri Cantiere',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Impostazioni',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openSettings(context),
              icon: const Icon(
                Icons.settings_outlined,
              ),
              label: const Text(
                'Apri Impostazioni',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
