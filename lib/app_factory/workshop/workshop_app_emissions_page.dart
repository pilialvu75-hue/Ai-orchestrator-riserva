import 'package:flutter/material.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';

typedef WorkshopEmissionAction = Future<void> Function(
    WorkshopAppEmissionPackage);

class WorkshopAppEmissionsPage extends StatefulWidget {
  const WorkshopAppEmissionsPage({
    super.key,
    required this.packages,
    this.openApp,
    this.revealFiles,
  });

  final List<WorkshopAppEmissionPackage> packages;
  final WorkshopEmissionAction? openApp;
  final WorkshopEmissionAction? revealFiles;

  @override
  State<WorkshopAppEmissionsPage> createState() =>
      _WorkshopAppEmissionsPageState();
}

class _WorkshopAppEmissionsPageState extends State<WorkshopAppEmissionsPage> {
  bool _opening = false;

  Future<void> _invoke(
      WorkshopEmissionAction action, WorkshopAppEmissionPackage package) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await action(package);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Impossibile aprire il risultato. Controlla che i file siano ancora disponibili.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final packages =
        widget.packages.where((package) => package.isReady).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('App emesse')),
      body: packages.isEmpty
          ? const Center(child: Text('Non ci sono ancora app emesse.'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: packages.length,
              itemBuilder: (context, index) {
                final package = packages[index];
                final date = package.createdAt.toLocal();
                return Card(
                    child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(package.appName ?? 'App del Cantiere',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                            '${package.target.toUpperCase()} · ${date.day}/${date.month}/${date.year}'),
                        if (widget.openApp != null ||
                            widget.revealFiles != null) ...[
                          const SizedBox(height: 12),
                          Wrap(spacing: 12, runSpacing: 8, children: [
                            if (widget.openApp != null &&
                                package.target == 'windows')
                              FilledButton.icon(
                                onPressed: _opening
                                    ? null
                                    : () => _invoke(widget.openApp!, package),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Avvia app'),
                              ),
                            if (widget.revealFiles != null)
                              OutlinedButton.icon(
                                onPressed: _opening
                                    ? null
                                    : () =>
                                        _invoke(widget.revealFiles!, package),
                                icon: const Icon(Icons.folder_open),
                                label: const Text('Apri cartella'),
                              ),
                          ]),
                        ],
                      ]),
                ));
              },
            ),
    );
  }
}
