import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ai_orchestrator/core/voice/sherpa_onnx_voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_cubit.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_service.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_state.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_runtime_manifest.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class ModelManagementPage extends StatelessWidget {
  const ModelManagementPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ModelManagementCubit>(
      create: (_) => ModelManagementCubit(
        service: di.sl<ModelManagementService>(),
        voiceEngine: di.sl<VoiceEngine>(),
        directVoiceEngine: di.sl<SherpaOnnxVoiceEngine>(),
      )..scanIntegrity(),
      child: const _ModelManagementView(),
    );
  }
}

class _ModelManagementView extends StatelessWidget {
  const _ModelManagementView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Gestione e Ripristino Voice Engine',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: BlocBuilder<ModelManagementCubit, ModelManagementState>(
        builder: (context, state) {
          final cubit = context.read<ModelManagementCubit>();
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                FilledButton.icon(
                  onPressed: state.exportingAll
                      ? null
                      : () => cubit.exportAllModelsToPublicStorage(),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF34D399),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: state.exportingAll
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.file_upload_outlined),
                  label: Text(
                    state.exportingAll
                        ? 'Esportazione in corso...'
                        : 'Esporta Tutti i Modelli nello Storage Pubblico',
                  ),
                ),
                if (state.exportingAll) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: state.exportProgress,
                    minHeight: 4,
                    backgroundColor: const Color(0xFF1F2937),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Color(0xFF34D399)),
                  ),
                ],
                if ((state.exportMessage ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.exportMessage!,
                    style: TextStyle(
                      color: state.exportMessage!.toLowerCase().contains('completata')
                          ? const Color(0xFF34D399)
                          : const Color(0xFFF59E0B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (state.scanning)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(
                      minHeight: 2.2,
                      backgroundColor: Color(0xFF1F2937),
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                    ),
                  ),
                for (final section in ModelRuntimeManifest.sectionOrder) ...[
                  _SectionCard(
                    title: ModelRuntimeManifest.sectionTitles[section]!,
                    children: ModelRuntimeManifest.files
                        .where((file) => file.section == section)
                        .map(
                          (file) => _FileRow(
                            file: file,
                            status: state.integrityByFileId[file.id] ??
                                ModelFileIntegrityStatus.unknown,
                            progress: state.progressByFileId[file.id],
                            message: state.messageByFileId[file.id],
                            onForceDownload: () => cubit.forceDownload(file.id),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: state.repairingAll
                      ? null
                      : () => cubit.verifyAndRepairAll(),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: state.repairingAll
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.build_circle_outlined),
                  label: Text(
                    state.repairingAll
                        ? 'Riparazione in corso...'
                        : 'Verifica Integrità Voice e Ripara Tutto',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF151515),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        iconColor: const Color(0xFF8AB4F8),
        collapsedIconColor: const Color(0xFF8AB4F8),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: children,
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.status,
    required this.progress,
    required this.message,
    required this.onForceDownload,
  });

  final RuntimeModelFileSpec file;
  final ModelFileIntegrityStatus status;
  final double? progress;
  final String? message;
  final VoidCallback onForceDownload;

  @override
  Widget build(BuildContext context) {
    final isDownloading = progress != null;
    final (statusLabel, statusColor) = _statusMeta(status, isDownloading);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF101010),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${file.logicalName} - ${file.estimatedSizeLabel}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      file.fileName,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.56),
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: isDownloading ? null : onForceDownload,
                tooltip: 'Forza Download',
                color: const Color(0xFF8AB4F8),
                icon: Icon(
                  isDownloading ? Icons.downloading_rounded : Icons.download_rounded,
                ),
              ),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: const Color(0xFF1F2937),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
            ),
            const SizedBox(height: 5),
            Text(
              '${((progress ?? 0) * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          ],
          if ((message ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              style: const TextStyle(
                color: Color(0xFFF59E0B),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  (String, Color) _statusMeta(
    ModelFileIntegrityStatus status,
    bool isDownloading,
  ) {
    if (isDownloading) {
      return ('Download in corso', const Color(0xFF8AB4F8));
    }
    switch (status) {
      case ModelFileIntegrityStatus.presentPublicStorage:
        return ('Presente (Storage Pubblico)', const Color(0xFF34D399));
      case ModelFileIntegrityStatus.presentInternalStorage:
        return ('Presente (Storage Interno)', const Color(0xFF60A5FA));
      case ModelFileIntegrityStatus.missing:
        return ('Mancante', const Color(0xFFEF4444));
      case ModelFileIntegrityStatus.corrupted:
        return ('Corrotto / Dimensioni Errate', const Color(0xFFF59E0B));
      case ModelFileIntegrityStatus.interrupted:
        return ('Download Interrotto - Clicca per Riprovare', const Color(0xFFF59E0B));
      case ModelFileIntegrityStatus.failed:
        return ('Errore verifica/download', const Color(0xFFFB7185));
      case ModelFileIntegrityStatus.unknown:
        return ('Da verificare', const Color(0xFF9CA3AF));
    }
  }
}
