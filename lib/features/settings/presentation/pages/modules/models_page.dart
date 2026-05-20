import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/ai/model_manager.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  static const _modelManager = ModelManager();
  // Approx. 2.3GB threshold used to route high-memory models to desktop section.
  static const int _desktopModelSizeThresholdBytes = 2300000000;

  String? _lastRequestedModelId;
  final Map<String, String> _statusOverrides = {};

  // Track whether we have already shown the update dialog for the current
  // batch of available updates, to avoid re-showing it on every rebuild.
  final Set<String> _shownUpdateIds = {};

  @override
  void initState() {
    super.initState();
    final bloc = context.read<ModelDownloadBloc>();
    if (bloc.state is ModelDownloadInitial) {
      bloc.add(const LoadAvailableModels());
    }
  }

  String _deriveCustomModelId(String url) {
    final uri = Uri.tryParse(url);
    final fallbackName =
        'custom_model_${DateTime.now().millisecondsSinceEpoch}.gguf';
    String fileName = fallbackName;
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      if (last.isNotEmpty) {
        fileName = last;
      }
    }
    return 'custom_${fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
  }

  /// Returns a status key string that encodes both download and validation
  /// state for a given model.
  ///
  /// Priority (highest → lowest):
  ///  1. 'downloading'      – active transfer in progress
  ///  2. 'error'            – session-level transfer error (UI override)
  ///  3. 'update_available' – valid model with a newer remote version
  ///  4. 'invalid'          – file failed GGUF validation
  ///  5. 'validated'        – file passed GGUF validation
  ///  6. 'ready'            – file on disk but not yet validated (legacy)
  ///  7. 'idle'             – not downloaded
  String _modelStatusFor(AiModel model, ModelsLoaded state) {
    if (state.downloadProgress.containsKey(model.id)) return 'downloading';
    if (_statusOverrides[model.id] == 'error') return 'error';
    final hasUpdate =
        state.updatableModels.any((u) => u.id == model.id);
    if (model.validationStatus == ModelValidationStatus.invalidModel) {
      return 'invalid';
    }
    if (model.validationStatus == ModelValidationStatus.missingFile) {
      return 'missing';
    }
    if (hasUpdate && model.isDownloaded) return 'update_available';
    if (model.validationStatus == ModelValidationStatus.validatedOk) {
      return 'validated';
    }
    if (model.isDownloaded) return 'ready';
    return 'idle';
  }

  bool _isDesktopModel(AiModel model) {
    final target = (model.platformTarget ?? 'all').toLowerCase();
    if (target == 'windows' ||
        target == 'linux' ||
        target == 'macos' ||
        target == 'desktop' ||
        target == 'pc') {
      return true;
    }
    return model.sizeBytes >= _desktopModelSizeThresholdBytes;
  }

  bool _isMobileModel(AiModel model) {
    if (_isDesktopModel(model)) return false;
    final target = (model.platformTarget ?? 'all').toLowerCase();
    if (target == 'android' ||
        target == 'ios' ||
        target == 'iphone' ||
        target == 'mobile') {
      return true;
    }
    if (target == 'all' || target.isEmpty) {
      return true;
    }
    // Unknown targets default to mobile unless already classified as desktop.
    return true;
  }

  void _showImportModelDialog() {
    final l10n = context.l10n;
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.t('import_model_from_url')),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: l10n.t('model_url'),
                  hintText: 'https://.../model.gguf',
                ),
                validator: (value) {
                  final raw = value?.trim() ?? '';
                  if (raw.isEmpty) return l10n.t('url_required');
                  final uri = Uri.tryParse(raw);
                  if (uri == null ||
                      !(uri.hasScheme && uri.host.isNotEmpty) ||
                      !(uri.scheme == 'http' || uri.scheme == 'https')) {
                    return l10n.t('valid_http_url');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: l10n.t('display_name_optional'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final url = urlController.text.trim();
              final displayName = nameController.text.trim().isNotEmpty
                  ? nameController.text.trim()
                  : url.split('/').last;
              final modelId = _deriveCustomModelId(url);
              setState(() {
                _lastRequestedModelId = modelId;
                _statusOverrides.remove(modelId);
              });
              context.read<ModelDownloadBloc>().add(
                    StartCustomUrlDownload(url: url, displayName: displayName),
                  );
              Navigator.pop(ctx);
            },
            child: Text(l10n.t('import')),
          ),
        ],
      ),
    );
  }

  void _importLocalModel({String? existingModelId}) {
    context
        .read<ModelDownloadBloc>()
        .add(StartLocalModelImport(existingModelId: existingModelId));
  }

  void _showUpdateDialog(
      BuildContext context, List<AiModel> updatableModels) {
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            const Icon(Icons.system_update_alt,
                color: Color(0xFF8AB4F8), size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.t('new_model_version_title'),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('new_model_version_body'),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 10),
            for (final model in updatableModels)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.circle,
                        color: Color(0xFF8AB4F8), size: 6),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        model.displayName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'v${model.version}',
                      style: const TextStyle(
                          color: Color(0xFF8AB4F8), fontSize: 11),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              l10n.t('update_model_confirm'),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('later'),
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showUpdateDetailsDialog(context, updatableModels);
            },
            child: Text(l10n.t('details'),
                style: const TextStyle(color: Color(0xFF8AB4F8))),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Trigger re-download for each updatable model.
              for (final model in updatableModels) {
                context
                    .read<ModelDownloadBloc>()
                    .add(StartModelDownload(model: model));
              }
            },
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF8AB4F8),
                foregroundColor: const Color(0xFF0D0D0D)),
            child: Text(l10n.t('update')),
          ),
        ],
      ),
    );
  }

  void _showUpdateDetailsDialog(
      BuildContext context, List<AiModel> updatableModels) {
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(l10n.t('details'),
            style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final model in updatableModels)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.upgrade,
                    color: Color(0xFF8AB4F8), size: 18),
                title: Text(model.displayName,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
                subtitle: Text(
                  '${l10n.t('update_available')} \u2192 v${model.version}',
                  style: const TextStyle(
                      color: Color(0xFF8AB4F8), fontSize: 11),
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.t('cancel')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          l10n.t('models'),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w500),
        ),
        actions: [
          IconButton(
            onPressed: _importLocalModel,
            tooltip: l10n.t('import_local_model'),
            icon: const Icon(Icons.folder_open, color: Color(0xFF8AB4F8)),
          ),
          TextButton.icon(
            onPressed: _showImportModelDialog,
            icon: const Icon(Icons.add_link, size: 18, color: Color(0xFF8AB4F8)),
            label: Text(
              l10n.t('import_url'),
              style: const TextStyle(color: Color(0xFF8AB4F8)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: BlocConsumer<ModelDownloadBloc, ModelDownloadState>(
          listener: (context, state) {
            if (state is ModelsLoaded && state.downloadErrorMessage != null) {
              if (_lastRequestedModelId != null) {
                setState(
                    () => _statusOverrides[_lastRequestedModelId!] = 'error');
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.downloadErrorMessage!),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
            }
            if (state is ModelDownloadError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
              );
            }
            if (state is ModelsLoaded &&
                _lastRequestedModelId != null &&
                !state.downloadProgress.containsKey(_lastRequestedModelId)) {
              AiModel? match;
              for (final model in state.models) {
                if (model.id == _lastRequestedModelId) {
                  match = model;
                  break;
                }
              }
              if (match?.isDownloaded == true) {
                setState(() => _statusOverrides.remove(_lastRequestedModelId));
              }
            }
            if (state is ModelsLoaded && state.updatableModels.isNotEmpty) {
              final newUpdateIds =
                  state.updatableModels.map((m) => m.id).toSet();
              if (newUpdateIds.difference(_shownUpdateIds).isNotEmpty) {
                _shownUpdateIds
                  ..clear()
                  ..addAll(newUpdateIds);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _showUpdateDialog(context, state.updatableModels);
                  }
                });
              }
            }
          },
          builder: (context, state) {
            if (state is ModelDownloadLoading && state is! ModelsLoaded) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFF8AB4F8)),
              );
            }
            final models = state is ModelsLoaded ? state.models : <AiModel>[];
            final selectedModelId =
                state is ModelsLoaded ? state.selectedModelId : null;
            final recommendedId = _modelManager.getRecommendedModelId(models);
            final mobileModels = models.where(_isMobileModel).toList(growable: false);
            final desktopModels =
                models.where(_isDesktopModel).toList(growable: false);

            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              children: [
                const _ModelSectionHeader(
                  title: 'Mobile models (Android / iOS)',
                  subtitle:
                      'Lightweight quantized GGUF models filtered for mobile runtime compatibility.',
                ),
                for (final model in mobileModels)
                  _ModelConfigTile(
                    model: model,
                    status: state is ModelsLoaded
                        ? _modelStatusFor(model, state)
                        : 'idle',
                    isSelected: selectedModelId == model.id,
                    isRecommended: model.id == recommendedId,
                    progress: state is ModelsLoaded
                        ? state.downloadProgress[model.id]
                        : null,
                    onDownload: () {
                      setState(() {
                        _lastRequestedModelId = model.id;
                        _statusOverrides.remove(model.id);
                      });
                      context.read<ModelDownloadBloc>().add(
                            StartModelDownload(model: model),
                          );
                    },
                    onCancel: () => context
                        .read<ModelDownloadBloc>()
                        .add(CancelModelDownload(modelId: model.id)),
                    onSetActive: () => context
                        .read<ModelDownloadBloc>()
                        .add(SelectActiveModel(modelId: model.id)),
                    onRelink: model.isImportedModel
                        ? () => _importLocalModel(existingModelId: model.id)
                        : null,
                  ),
                const SizedBox(height: 10),
                const _ModelSectionHeader(
                  title: 'Desktop models (Windows / Linux / macOS)',
                  subtitle:
                      'Large/high-context models filtered for desktop-class runtime capacity.',
                ),
                for (final model in desktopModels)
                  _ModelConfigTile(
                    model: model,
                    status: state is ModelsLoaded
                        ? _modelStatusFor(model, state)
                        : 'idle',
                    isSelected: selectedModelId == model.id,
                    isRecommended: model.id == recommendedId,
                    progress: state is ModelsLoaded
                        ? state.downloadProgress[model.id]
                        : null,
                    onDownload: () {
                      setState(() {
                        _lastRequestedModelId = model.id;
                        _statusOverrides.remove(model.id);
                      });
                      context.read<ModelDownloadBloc>().add(
                            StartModelDownload(model: model),
                          );
                    },
                    onCancel: () => context
                        .read<ModelDownloadBloc>()
                        .add(CancelModelDownload(modelId: model.id)),
                    onSetActive: () => context
                        .read<ModelDownloadBloc>()
                        .add(SelectActiveModel(modelId: model.id)),
                    onRelink: model.isImportedModel
                        ? () => _importLocalModel(existingModelId: model.id)
                        : null,
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => context
                        .read<ModelDownloadBloc>()
                        .add(const LoadAvailableModels()),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.t('refresh_models')),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ModelSectionHeader extends StatelessWidget {
  const _ModelSectionHeader({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.56),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelConfigTile extends StatelessWidget {
  const _ModelConfigTile({
    required this.model,
    required this.status,
    required this.isSelected,
    required this.isRecommended,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    required this.onSetActive,
    this.onRelink,
  });

  final AiModel model;
  final String status;
  final bool isSelected;
  final bool isRecommended;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onSetActive;
  final VoidCallback? onRelink;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final statusColor = switch (status) {
      'validated' => const Color(0xFF4CAF50),
      'ready' => const Color(0xFF4CAF50),
      'downloading' => const Color(0xFF8AB4F8),
      'update_available' => const Color(0xFFFFA726),
      'invalid' => const Color(0xFFFF7043),
      'missing' => const Color(0xFFEF5350),
      'error' => const Color(0xFFEF5350),
      _ => Colors.white38,
    };

    final statusLabel = switch (status) {
      'validated' => l10n.t('model_validated'),
      'ready' => l10n.t('model_validated'),
      'downloading' => '\u2026',
      'update_available' => l10n.t('update_available'),
      'invalid' => l10n.t('model_invalid'),
      'missing' => l10n.t('model_missing_file'),
      'error' => 'error',
      _ => null,
    };

    // A model can only be set active when it is on disk AND passed validation.
    final canSetActive = model.isDownloaded &&
        !isSelected &&
        status != 'invalid' &&
        status != 'missing' &&
        status != 'error' &&
        (!model.isImportedModel || model.runtimeModelId != null);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected
              ? const Color(0xFF8AB4F8)
              : Colors.white.withValues(alpha: 0.08),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              // Status badge
              if (statusLabel != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (isSelected) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8AB4F8).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.t('active'),
                    style: const TextStyle(
                        color: Color(0xFF8AB4F8),
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (isRecommended) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6ECBF5).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.t('recommended'),
                    style: const TextStyle(
                        color: Color(0xFF6ECBF5),
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (model.isImportedModel) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF81C784).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.t('imported_model'),
                    style: const TextStyle(
                        color: Color(0xFF81C784),
                        fontSize: 10,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            model.description,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
          ),
          if (model.isImportedModel && model.localPath != null) ...[
            const SizedBox(height: 6),
            Text(
              '${l10n.t('local_model_path')}: ${model.localPath}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.38),
                fontSize: 11,
              ),
            ),
          ],
          if (status == 'invalid') ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 13, color: Color(0xFFFF7043)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l10n.t('model_invalid'),
                    style: const TextStyle(
                        color: Color(0xFFFF7043), fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          if (status == 'missing') ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.link_off,
                    size: 13, color: Color(0xFFEF5350)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l10n.t('model_missing_file'),
                    style: const TextStyle(
                        color: Color(0xFFEF5350), fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${((progress ?? 0) * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    color: Color(0xFF8AB4F8), fontSize: 11),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (status == 'downloading')
                OutlinedButton(
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white24),
                    foregroundColor: Colors.white70,
                  ),
                  child: Text(l10n.t('cancel')),
                )
              else if (!model.isDownloaded || status == 'invalid')
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download, size: 16),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: const Color(0xFF0D0D0D),
                   ),
                   label: Text(
                     status == 'invalid'
                         ? l10n.t('re_download')
                         : l10n.t('download'),
                   ),
                 )
               else if (status == 'missing' && onRelink != null)
                 FilledButton.icon(
                   onPressed: onRelink,
                   icon: const Icon(Icons.link, size: 16),
                   style: FilledButton.styleFrom(
                     backgroundColor: const Color(0xFF8AB4F8),
                     foregroundColor: const Color(0xFF0D0D0D),
                   ),
                   label: Text(l10n.t('relink_model')),
                 )
               else if (status == 'update_available')
                 FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.upgrade, size: 16),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFFA726),
                    foregroundColor: const Color(0xFF0D0D0D),
                  ),
                  label: Text(l10n.t('update')),
                )
              else if (canSetActive)
                FilledButton(
                  onPressed: onSetActive,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: const Color(0xFF0D0D0D),
                  ),
                  child: Text(l10n.t('use_this_model')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
