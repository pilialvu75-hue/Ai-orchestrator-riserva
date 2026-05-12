import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/ai/model_manager.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/widgets/model_download_card.dart';

/// Dedicated page for browsing, downloading and selecting local AI models.
///
/// This page is accessible from the [ChatPage] drawer and operates entirely
/// in the background — a failure to load the model list never blocks the
/// main chat UI.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  static const _modelManager = ModelManager();
  // Approx. 2.3GB threshold used to route high-memory models to desktop section.
  static const int _desktopModelSizeThresholdBytes = 2300000000;

  @override
  void initState() {
    super.initState();
    // Kick off the model list load only when data has not been fetched yet.
    final bloc = context.read<ModelDownloadBloc>();
    if (bloc.state is ModelDownloadInitial) {
      bloc.add(const LoadAvailableModels());
    }
  }

  // ── Custom URL download dialog ──────────────────────────────────────────────

  void _showAddCustomModelDialog() {
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Add custom model',
            style: TextStyle(color: Colors.white)),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Paste a direct download URL from Hugging Face, Ollama Hub '
                'or any other GGUF host.',
                style:
                    TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: urlController,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Model URL (.gguf)'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'URL required';
                  if (!v.trim().startsWith('http')) return 'Enter a valid URL';
                  return null;
                },
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Display name (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final url = urlController.text.trim();
              final name = nameController.text.trim().isNotEmpty
                  ? nameController.text.trim()
                  : url.split('/').last;
              context.read<ModelDownloadBloc>().add(
                    StartCustomUrlDownload(url: url, displayName: name),
                  );
              Navigator.pop(ctx);
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Color(0xFF8AB4F8)),
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.red.shade400),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.red.shade400),
          borderRadius: BorderRadius.circular(8),
        ),
        errorStyle: TextStyle(color: Colors.red.shade400),
      );

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

  bool _isMobileModel(AiModel model) => !_isDesktopModel(model);

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'AI Models',
          style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: () => context
                .read<ModelDownloadBloc>()
                .add(const LoadAvailableModels()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddCustomModelDialog,
        backgroundColor: const Color(0xFF8AB4F8),
        foregroundColor: const Color(0xFF0D0D0D),
        icon: const Icon(Icons.add_link),
        label: const Text('Add model URL'),
      ),
      body: BlocConsumer<ModelDownloadBloc, ModelDownloadState>(
        listener: (context, state) {
          if (state is ModelDownloadError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: Theme.of(context).colorScheme.error,
                action: SnackBarAction(
                  label: 'Retry',
                  textColor: Colors.white,
                  onPressed: () => context
                      .read<ModelDownloadBloc>()
                      .add(const LoadAvailableModels()),
                ),
              ),
            );
          }
          // Per-download error: surface without blanking the list.
          if (state is ModelsLoaded &&
              state.downloadErrorMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.downloadErrorMessage!),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        },
        builder: (context, state) {
          if (state is ModelDownloadInitial || state is ModelDownloadLoading) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFF8AB4F8)),
            );
          }

          if (state is ModelDownloadError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off,
                        color: Colors.white54, size: 56),
                    const SizedBox(height: 16),
                    Text(
                      state.message,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => context
                          .read<ModelDownloadBloc>()
                          .add(const LoadAvailableModels()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final models =
              state is ModelsLoaded ? state.models : <AiModel>[];
          final selectedModelId =
              state is ModelsLoaded ? state.selectedModelId : null;
          final downloadProgress =
              state is ModelsLoaded ? state.downloadProgress : <String, double>{};
          final recommendedId = _modelManager.getRecommendedModelId(models);

          if (models.isEmpty) {
            return const Center(
              child: Text(
                'No models available.',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }

          final mobileModels = models.where(_isMobileModel).toList(growable: false);
          final desktopModels =
              models.where(_isDesktopModel).toList(growable: false);

          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 96),
            children: [
              const _ModelSectionHeader(
                title: 'Mobile models (Android / iOS)',
                subtitle: 'Lightweight and low-RAM compatible options.',
              ),
              for (final model in mobileModels)
                ModelDownloadCard(
                  model: model,
                  isSelected: selectedModelId == model.id,
                  isRecommended: model.id == recommendedId,
                  downloadProgress: downloadProgress[model.id],
                  onDownload: () => context
                      .read<ModelDownloadBloc>()
                      .add(StartModelDownload(model: model)),
                  onCancel: () => context
                      .read<ModelDownloadBloc>()
                      .add(CancelModelDownload(modelId: model.id)),
                  onSelect: () => context
                      .read<ModelDownloadBloc>()
                      .add(SelectActiveModel(modelId: model.id)),
                ),
              const SizedBox(height: 8),
              const _ModelSectionHeader(
                title: 'Desktop models (Windows / Linux / macOS)',
                subtitle: 'Higher-capacity models for desktop-class devices.',
              ),
              for (final model in desktopModels)
                ModelDownloadCard(
                  model: model,
                  isSelected: selectedModelId == model.id,
                  isRecommended: model.id == recommendedId,
                  downloadProgress: downloadProgress[model.id],
                  onDownload: () => context
                      .read<ModelDownloadBloc>()
                      .add(StartModelDownload(model: model)),
                  onCancel: () => context
                      .read<ModelDownloadBloc>()
                      .add(CancelModelDownload(modelId: model.id)),
                  onSelect: () => context
                      .read<ModelDownloadBloc>()
                      .add(SelectActiveModel(modelId: model.id)),
                ),
            ],
          );
        },
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withOpacity(0.56),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
