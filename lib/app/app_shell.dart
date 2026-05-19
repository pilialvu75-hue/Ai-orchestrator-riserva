import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/core/system/update/update_manifest.dart';
import 'package:ai_orchestrator/core/system/update/update_state.dart';
import 'package:ai_orchestrator/features/chat/presentation/pages/chat_page.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/settings_page.dart';
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

  @override
  void initState() {
    super.initState();
    _updateManager = di.sl<UpdateManager>();
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _updateManager.state.addListener(_onUpdateStateChanged);
    unawaited(
      _updateManager.startBackgroundChecks(
        interval: AppConstants.updateCheckInterval,
      ),
    );
    unawaited(_runtimeDiagnostics.validateOnStartup());
  }

  void _onUpdateStateChanged() {
    final currentState = _updateManager.state.value;
    final latest = currentState.latestManifest;
    if (!mounted || latest == null) return;

    if (currentState.status == UpdateStatus.updateAvailable &&
        _shownUpdateVersion != latest.version) {
      _shownUpdateVersion = latest.version;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUpdateDialog(latest);
        }
      });
    }
  }

  @override
  void dispose() {
    _updateManager.state.removeListener(_onUpdateStateChanged);
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

  String _resolveActiveModel(BuildContext context, ModelDownloadState state) {
    final l10n = context.l10n;
    if (state is! ModelsLoaded || state.selectedModelId == null) {
      return l10n.t('no_local_model');
    }

    for (final model in state.models) {
      if (model.id == state.selectedModelId) {
        return model.displayName;
      }
    }

    return l10n.t('no_local_model');
  }

  Future<void> _showUpdateDialog(UpdateManifest manifest) async {
    final l10n = context.l10n;
    final currentVersion = _updateManager.currentVersion;
    final preview = manifest.changelog.trim().isEmpty
        ? 'No changelog available.'
        : manifest.changelog.trim().split('\n').take(4).join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: Text(
          l10n.t('new_version_available'),
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${l10n.t('current_version')}: $currentVersion',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Text(
              '${l10n.t('latest_version')}: ${manifest.version}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            const Text(
              'Changelog preview',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              preview,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.t('dismiss'),
              style: TextStyle(color: Colors.white54),
            ),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _showDownloadDialog();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8AB4F8),
              foregroundColor: const Color(0xFF0D0D0D),
            ),
            child: Text(l10n.t('update')),
          ),
        ],
      ),
    );
  }

  Future<void> _showDownloadDialog() async {
    final l10n = context.l10n;
    unawaited(_updateManager.downloadLatestApk());
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<UpdateState>(
        valueListenable: _updateManager.state,
        builder: (_, state, __) {
          final isDownloading = state.status == UpdateStatus.downloading;
          final ready = state.status == UpdateStatus.readyToInstall;
          final hasError = state.status == UpdateStatus.error;
          return AlertDialog(
            backgroundColor: const Color(0xFF121212),
            title: Text(
              l10n.t('update_download_title'),
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isDownloading) ...[
                  LinearProgressIndicator(
                    value: state.downloadProgress <= 0
                        ? null
                        : state.downloadProgress,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${(state.downloadProgress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ] else if (ready) ...[
                  const Text(
                    'APK downloaded and ready. Tap Install to continue.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ] else if (hasError) ...[
                  Text(
                    state.errorMessage ?? 'Failed to download update.',
                    style: const TextStyle(color: Color(0xFFFF8A80)),
                  ),
                ] else ...[
                  const Text(
                    'Preparing update download…',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isDownloading ? null : () => Navigator.pop(ctx),
                child: Text(
                  l10n.t('close'),
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              if (ready)
                FilledButton(
                  onPressed: () async {
                      final nav = Navigator.of(ctx);
                      await _updateManager.prepareInstallIntent();
                      if (!mounted) return;
                      nav.pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: const Color(0xFF0D0D0D),
                  ),
                  child: Text(l10n.t('install')),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      appBar: _AppShellAppBar(
        resolveActiveModel: (state) => _resolveActiveModel(context, state),
        onSettings: () => _openSettings(context),
      ),
      body: const ChatPage(),
    );
  }
}

class _AppShellAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _AppShellAppBar({
    required this.resolveActiveModel,
    required this.onSettings,
  });

  final String Function(ModelDownloadState) resolveActiveModel;
  final VoidCallback onSettings;

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 72,
      iconTheme: const IconThemeData(color: Colors.white),
      titleSpacing: 16,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF171E33).withValues(alpha: 0.96),
              const Color(0xFF0D0D0D).withValues(alpha: 0.94),
            ],
          ),
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x2215B6FF),
              blurRadius: 26,
              offset: Offset(0, 8),
            ),
          ],
        ),
      ),
      title: BlocBuilder<ModelDownloadBloc, ModelDownloadState>(
        builder: (context, modelState) {
          return Align(
            alignment: Alignment.centerLeft,
            child: _AnimatedModelChip(
              label: _removeSizeSuffixFromLabel(resolveActiveModel(modelState)),
              onTap: onSettings,
            ),
          );
        },
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: _GlassIconButton(
            tooltip: context.l10n.t('settings'),
            icon: Icons.settings_outlined,
            onPressed: onSettings,
          ),
        ),
      ],
    );
  }
}

/// Removes trailing size suffixes such as `1B` or `3.2B` from a model label.
///
/// The regex matches whitespace plus a decimal/integer number followed by `B`
/// at the end of the string, so labels like `Llama 3.2 1B` lose only their
/// final size suffix and become `Llama 3.2`.
String _removeSizeSuffixFromLabel(String label) {
  return label.replaceFirst(RegExp(r'\s+\d+(?:\.\d+)?B$'), '');
}

class _AnimatedModelChip extends StatefulWidget {
  const _AnimatedModelChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  State<_AnimatedModelChip> createState() => _AnimatedModelChipState();
}

class _AnimatedModelChipState extends State<_AnimatedModelChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final glow = 0.18 + (_controller.value * 0.18);
        return InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF202B45).withValues(alpha: 0.98),
                  const Color(0xFF131C2A).withValues(alpha: 0.97),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xFF8AB4F8).withValues(alpha: 0.34 + glow),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF60A5FA).withValues(alpha: glow),
                  blurRadius: 20,
                  spreadRadius: 0.6,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                  color: Colors.white70,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1A8AB4F8),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white70, size: 20),
        ),
      ),
    );
  }
}
