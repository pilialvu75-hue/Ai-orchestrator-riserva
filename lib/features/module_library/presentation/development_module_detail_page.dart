import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_library_development_source.dart';
import 'package:ai_orchestrator/features/module_library/data/module_library_status_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Visible, verifiable and exportable developer source. Previewing this
/// package never loads arbitrary Dart into Flutter's production runtime.
class DevelopmentModuleDetailPage extends StatefulWidget {
  const DevelopmentModuleDetailPage({
    super.key,
    required this.entry,
    required this.repository,
  });

  final ModuleDevelopmentEntry entry;
  final ModuleLibraryStatusRepository repository;

  @override
  State<DevelopmentModuleDetailPage> createState() =>
      _DevelopmentModuleDetailPageState();
}

class _DevelopmentModuleDetailPageState
    extends State<DevelopmentModuleDetailPage> {
  late Future<ModuleDevelopmentPackage> _verification;

  @override
  void initState() {
    super.initState();
    _verification = widget.repository.loadDevelopmentPackage(widget.entry);
  }

  void _retry() {
    setState(() {
      _verification = widget.repository.loadDevelopmentPackage(widget.entry);
    });
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(label)),
    );
  }

  Future<void> _openEvidence() async {
    final url = Uri.parse(
      'https://github.com/pilialvu75-hue/AI-Orchestrator-Module-Library/'
      'actions/runs/${widget.entry.consumerRunId}',
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossibile aprire la prova GitHub.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry.shortName)),
      body: FutureBuilder<ModuleDevelopmentPackage>(
        future: _verification,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Sorgente non verificabile: ${snapshot.error}'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Riprova'),
                ),
              ],
            );
          }
          final pkg = snapshot.requireData;
          final source = pkg.sourceSummary;
          final bundle = jsonEncode(<String, Object?>{
            'pin': pkg.entry.pin,
            'package_sha256': pkg.entry.packageSha256,
            'status': 'development_qualified',
            'usage': 'internal-development-only',
            'files': pkg.files,
          });
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Modulo di sviluppo verificato',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              SelectableText(widget.entry.pin),
              const SizedBox(height: 8),
              const Text(
                'I sorgenti sotto sono stati scaricati dalla Libreria e '
                'confrontati con SHA256 del pacchetto originale. Il consumer '
                'indipendente ha funzionato su Linux. Nessuna prova Android, '
                'installazione automatica o certificazione di produzione.',
              ),
              const SizedBox(height: 12),
              Text('Piattaforme verificate: ${widget.entry.targets.join(', ')}'),
              Text('Contratti: ${pkg.contracts.join(', ')}'),
              Text('Prova indipendente: run #${widget.entry.consumerRunId} — PASS'),
              const SizedBox(height: 8),
              SelectableText(
                'SHA256: ${widget.entry.packageSha256}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: source.isEmpty
                        ? null
                        : () => _copy(source, 'Codice Dart copiato.'),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copia codice Dart'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _copy(
                      bundle,
                      'Pacchetto sorgenti copiato per il Cantiere.',
                    ),
                    icon: const Icon(Icons.file_copy_outlined),
                    label: const Text('Copia pacchetto'),
                  ),
                  TextButton.icon(
                    onPressed: _openEvidence,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Vedi test GitHub'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Sorgenti del modulo',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final file in pkg.files.entries)
                ExpansionTile(
                  title: Text(file.key),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        file.value,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
