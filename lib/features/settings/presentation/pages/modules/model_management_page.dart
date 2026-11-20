import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/voice/voice_tts_preference.dart';
import 'package:file_picker/file_picker.dart';
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
                if (Platform.isAndroid) const _VoiceTtsSelector(),
                if (Platform.isAndroid) const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'I download avviati proseguono anche con l’app chiusa. '
                    'Segui la notifica Android. Alla riapertura, premi di nuovo '
                    'Scarica sullo stesso pacchetto per completarne la preparazione: '
                    'il trasferimento già avviato viene recuperato.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                FilledButton.icon(
                  onPressed: state.exportingAll
                      ? null
                      : () async {
                          String? destinationDirectory;
                          if (!Platform.isAndroid) {
                            destinationDirectory =
                                await FilePicker.platform.getDirectoryPath(
                              dialogTitle:
                                  'Scegli dove salvare il backup dei modelli',
                            );
                            if (destinationDirectory == null ||
                                destinationDirectory.trim().isEmpty) {
                              return;
                            }
                          }
                          await cubit.exportAllModelsToPublicStorage(
                            destinationDirectory: destinationDirectory,
                          );
                        },
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
                        : Platform.isAndroid
                            ? 'Esporta Tutti i Modelli nello Storage Pubblico'
                            : 'Esporta Tutti i Modelli in una Cartella',
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
      case ModelFileIntegrityStatus.incomplete:
        return ('Download Incompleto — Riprova', const Color(0xFFF59E0B));
      case ModelFileIntegrityStatus.corrupted:
        return ('Corrotto / Dati Non Validi', const Color(0xFFF59E0B));
      case ModelFileIntegrityStatus.interrupted:
        return ('Download Interrotto — Fare clic per Riprovare', const Color(0xFFF59E0B));
      case ModelFileIntegrityStatus.failed:
        return ('Errore verifica/download', const Color(0xFFFB7185));
      case ModelFileIntegrityStatus.unknown:
        return ('Da verificare', const Color(0xFF9CA3AF));
    }
  }
}


/// Audio-output choice is deliberately separate from the existing STT model
/// integrity/download settings. Unsupported alternatives are not selectable.
class _VoiceTtsSelector extends StatefulWidget {
  const _VoiceTtsSelector();

  @override
  State<_VoiceTtsSelector> createState() => _VoiceTtsSelectorState();
}

class _VoiceTtsSelectorState extends State<_VoiceTtsSelector> {
  TtsBackend _selected = TtsBackend.kokoro;
  bool _busy = true;
  bool _androidAvailable = false;
  List<String> _languages = const [];
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final backend = await VoiceTtsPreference.read();
    final status = await VoiceTtsPreference.inspectAndroid();
    final voices = status['voices'];
    final languages = <String>{};
    if (voices is List) {
      for (final voice in voices) {
        if (voice is Map) {
          final locale = voice['language']?.toString();
          if (locale != null && locale.isNotEmpty) languages.add(locale);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _selected = backend;
      _androidAvailable = status['ready'] == true && languages.isNotEmpty;
      _languages = languages.toList()..sort();
      _busy = false;
    });
  }

  Future<void> _change(TtsBackend backend) async {
    setState(() { _busy = true; _notice = null; });
    try {
      // End the previous PCM/native playback before switching engines.
      await di.sl<VoiceEngine>().stopSpeaking();
      await VoiceTtsPreference.save(backend);
      if (!mounted) return;
      setState(() {
        _selected = backend;
        _notice = 'Scelta salvata. La prossima lettura userà il motore selezionato.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _notice = 'Motore non disponibile. Kokoro resta utilizzabile.'; });
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  Future<void> _preview() async {
    setState(() { _busy = true; _notice = null; });
    try {
      final ok = await VoiceTtsPreference.channel.invokeMethod<bool>(
        'speak', <String, String>{'text': 'Ciao, questa è una prova della voce Android.', 'language': 'it'},
      );
      if (mounted) setState(() { _notice = ok == true ? 'Prova completata.' : 'Prova interrotta.'; });
    } catch (_) {
      if (mounted) setState(() { _notice = 'La voce italiana offline non è disponibile.'; });
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF151515),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Motore di lettura vocale (TTS)',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('La scelta riguarda Ascolta e Live. Il microfono e il modello IA rimangono invariati.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            RadioListTile<TtsBackend>(
              title: const Text('Kokoro — attuale', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Mantieni il modello vocale esistente.', style: TextStyle(color: Colors.white60)),
              value: TtsBackend.kokoro,
              groupValue: _selected,
              onChanged: _busy ? null : (v) { if (v != null) _change(v); },
            ),
            RadioListTile<TtsBackend>(
              title: const Text('Voci native Android — offline', style: TextStyle(color: Colors.white)),
              subtitle: Text(_androidAvailable
                  ? 'Disponibili: ${_languages.join(", ")}'
                  : 'Nessuna voce offline rilevata: verifica le voci installate su Android.',
                  style: const TextStyle(color: Colors.white60)),
              value: TtsBackend.androidSystem,
              groupValue: _selected,
              onChanged: _busy || !_androidAvailable ? null : (v) { if (v != null) _change(v); },
            ),
            const ListTile(
              dense: true,
              title: Text('Piper INT8 / Supertonic INT8', style: TextStyle(color: Colors.white70)),
              subtitle: Text('Alternative in preparazione: non ancora installabili in questa build.',
                  style: TextStyle(color: Colors.white54)),
              trailing: Icon(Icons.lock_clock, color: Colors.white54),
            ),
            Row(children: [
              TextButton(onPressed: _busy ? null : _load, child: const Text('Aggiorna voci')),
              if (_androidAvailable)
                TextButton(onPressed: _busy ? null : _preview, child: const Text('Prova Android')),
            ]),
            if (_busy) const LinearProgressIndicator(),
            if (_notice != null)
              Text(_notice!, style: const TextStyle(color: Color(0xFF8AB4F8), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
