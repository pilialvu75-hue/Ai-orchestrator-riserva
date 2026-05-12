// FILE COMPLETO AGGIORNATO — SETTINGS PAGE

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/system/update/update_manager.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/ai_mode_page.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/language_page.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/models_page.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/personal_data_page.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/system_prompt_page.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/update_settings_page.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AiRuntimeSettingsService _aiRuntimeSettingsService;
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;

  LocalRuntimeState _runtimeState = const LocalRuntimeState();

  @override
  void initState() {
    super.initState();

    _aiRuntimeSettingsService = di.sl<AiRuntimeSettingsService>();
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();

    _runtimeState = _runtimeDiagnostics.monitor.state;

    _runtimeDiagnostics.monitor.addListener(
      _handleRuntimeStateChanged,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshRuntimeDiagnostics();
    });
  }

  void _handleRuntimeStateChanged(LocalRuntimeState state) {
    if (!mounted) return;

    setState(() {
      _runtimeState = state;
    });
  }

  Future<void> _refreshRuntimeDiagnostics() async {
    try {
      await _runtimeDiagnostics.refresh();
    } catch (error) {
      debugPrint(
        'SettingsPage: runtime diagnostics refresh failed: $error',
      );
    }
  }

  String _createModelsSnapshot(ModelsLoaded state) {
    return state.models
        .map(
          (model) =>
              '${model.id}:${model.isDownloaded}:${model.validationStatus}:${model.localPath}',
        )
        .join('|');
  }

  @override
  void dispose() {
    _runtimeDiagnostics.monitor.removeListener(
      _handleRuntimeStateChanged,
    );

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return BlocListener<ModelDownloadBloc, ModelDownloadState>(
      listenWhen: (previous, current) {
        if (current is ModelDownloadError) {
          return true;
        }

        if (previous is ModelsLoaded && current is ModelsLoaded) {
          final previousFingerprint =
              _createModelsSnapshot(previous);

          final currentFingerprint =
              _createModelsSnapshot(current);

          return previous.selectedModelId !=
                  current.selectedModelId ||
              previousFingerprint != currentFingerprint;
        }

        return previous.runtimeType != current.runtimeType &&
            current is ModelsLoaded;
      },
      listener: (_, __) => _refreshRuntimeDiagnostics(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(
            color: Colors.white,
          ),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF171E33).withOpacity(0.96),
                  const Color(0xFF0D0D0D).withOpacity(0.94),
                ],
              ),
            ),
          ),
          title: Text(
            l10n.t('settings'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        body: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF101526).withOpacity(0.5),
                  const Color(0xFF0D0D0D),
                ],
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                18,
                18,
                18,
                24,
              ),
              children: [
                _SettingsHero(
                  runtimeState: _runtimeState,
                ),

                const SizedBox(height: 16),

                _ModuleCard(
                  icon: Icons.memory_outlined,
                  title: l10n.t('models'),
                  subtitle: l10n.t('models_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const ModelsPage(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),

                _ModuleCard(
                  icon: Icons.person_outline,
                  title: l10n.t('personal_data_optional'),
                  subtitle: l10n.t('personal_data_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const PersonalDataPage(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),

                _ModuleCard(
                  icon: Icons.language_outlined,
                  title: l10n.t('language'),
                  subtitle: l10n.t('language_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const LanguagePage(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),

                _ModuleCard(
                  icon: Icons.tune_outlined,
                  title: l10n.t('ai_mode'),
                  subtitle: l10n.t('ai_mode_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AiModePage(
                          settingsService:
                              _aiRuntimeSettingsService,
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),

                _ModuleCard(
                  icon: Icons.system_update_alt_outlined,
                  title: l10n.t('updates'),
                  subtitle: l10n.t('updates_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => UpdateSettingsPage(
                          updateManager:
                              di.sl<UpdateManager>(),
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),

                _ModuleCard(
                  icon: Icons.chat_bubble_outline,
                  title: l10n.t('system_prompt'),
                  subtitle:
                      l10n.t('system_prompt_subtitle'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const SystemPromptPage(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 32),

                Center(
                  child: Text(
                    'Editor by Roby P.',
                    style: TextStyle(
                      color:
                          Colors.white.withOpacity(0.4),
                      fontSize: 12,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsHero extends StatelessWidget {
  const _SettingsHero({
    required this.runtimeState,
  });

  final LocalRuntimeState runtimeState;

  String _titleForStatus(BuildContext context) {
    switch (runtimeState.status) {
      case LocalRuntimeStatus.ready:
        return context.l10n.t('runtime_ready');

      case LocalRuntimeStatus.loading:
        return context.l10n.t('runtime_loading');

      case LocalRuntimeStatus.tokenizing:
        return 'Preparing prompt...';

      case LocalRuntimeStatus.streaming:
        return 'Streaming response...';

      case LocalRuntimeStatus.inferring:
        return 'Generating response...';

      case LocalRuntimeStatus.stalled:
        return 'Model stalled...';

      case LocalRuntimeStatus.completed:
        return 'Completed';

      case LocalRuntimeStatus.timedOut:
        return 'Timed out';

      case LocalRuntimeStatus.missingLibrary:
        return context.l10n.t(
          'runtime_missing_library',
        );

      case LocalRuntimeStatus.modelMissing:
        return context.l10n.t(
          'runtime_model_missing',
        );

      case LocalRuntimeStatus.runtimeFailed:
        return context.l10n.t('runtime_failed');
    }
  }

  Color _accentForStatus() {
    switch (runtimeState.status) {
      case LocalRuntimeStatus.ready:
        return const Color(0xFF8AB4F8);

      case LocalRuntimeStatus.loading:
        return const Color(0xFF7DD3FC);

      case LocalRuntimeStatus.tokenizing:
        return const Color(0xFFA78BFA);

      case LocalRuntimeStatus.streaming:
        return const Color(0xFF34D399);

      case LocalRuntimeStatus.inferring:
        return const Color(0xFF34D399);

      case LocalRuntimeStatus.stalled:
        return const Color(0xFFFFB74D);

      case LocalRuntimeStatus.completed:
        return const Color(0xFF34D399);

      case LocalRuntimeStatus.timedOut:
        return const Color(0xFFFF8A80);

      case LocalRuntimeStatus.missingLibrary:
      case LocalRuntimeStatus.modelMissing:
        return const Color(0xFFF9A826);

      case LocalRuntimeStatus.runtimeFailed:
        return const Color(0xFFFF8A80);
    }
  }

  String _formatElapsed(Duration duration) {
    final seconds = duration.inSeconds;
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    if (minutes <= 0) return '${remaining}s';
    return '${minutes}m ${remaining}s';
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accentForStatus();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF161D2F)
                .withOpacity(0.98),
            const Color(0xFF101116)
                .withOpacity(0.96),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: accent.withOpacity(0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.12),
            blurRadius: 28,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.14),
                  borderRadius:
                      BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.bolt_rounded,
                  color: accent,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n
                          .t('local_runtime'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight:
                            FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      runtimeState.message ??
                          context.l10n.t(
                            'runtime_checked_automatically',
                          ),
                      style: TextStyle(
                        color: Colors.white
                            .withOpacity(0.6),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          Container(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color:
                  accent.withOpacity(0.12),
              borderRadius:
                  BorderRadius.circular(16),
              border: Border.all(
                color:
                    accent.withOpacity(0.2),
              ),
            ),
            child: Row(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent
                            .withOpacity(0.5),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                Text(
                  _titleForStatus(context),
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight:
                        FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Diagnostics · status=${runtimeState.status.name} · tokens=${runtimeState.tokensGenerated} · elapsed=${_formatElapsed(runtimeState.elapsed)}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.62),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF151515),
      borderRadius:
          BorderRadius.circular(14),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(14),
            border: Border.all(
              color:
                  Colors.white.withOpacity(
                0.08,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(
                    0xFF8AB4F8,
                  ).withOpacity(0.12),
                  borderRadius:
                      BorderRadius.circular(
                    11,
                  ),
                ),
                child: Icon(
                  icon,
                  color: Color(0xFF8AB4F8),
                  size: 22,
                ),
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style:
                          const TextStyle(
                        color: Colors.white,
                        fontWeight:
                            FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white
                            .withOpacity(0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              Icon(
                Icons.chevron_right,
                color: Colors.white
                    .withOpacity(0.3),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
