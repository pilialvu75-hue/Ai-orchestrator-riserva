import 'dart:async';

import 'package:ai_orchestrator/features/module_library/data/module_library_status_repository.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_capability_status.dart';
import 'package:flutter/material.dart';

class ModuleLibraryPage extends StatefulWidget {
  const ModuleLibraryPage({
    super.key,
    this.repository,
  });

  final ModuleLibraryStatusRepository? repository;

  @override
  State<ModuleLibraryPage> createState() => _ModuleLibraryPageState();
}

class _ModuleLibraryPageState extends State<ModuleLibraryPage> {
  late final ModuleLibraryStatusRepository _repository;
  bool _loading = true;
  String? _error;
  List<ModuleCapabilityStatus> _items = const <ModuleCapabilityStatus>[];

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ModuleLibraryStatusRepository();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _repository.load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moduli'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            onPressed: _loading ? null : () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _refresh)
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _CapabilityCard(status: _items[index]),
                  ),
                ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.status});

  final ModuleCapabilityStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                      Text(status.title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        status.capabilityId,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Chip(label: Text(status.statusLabel)),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: status.desiredCandidates == 0
                  ? 0
                  : (status.presentCount / status.desiredCandidates)
                      .clamp(0, 1)
                      .toDouble(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip('Certificati', '${status.presentCount}/${status.desiredCandidates}'),
                if (status.research.available)
                  _InfoChip('Candidati', '${status.research.candidateCount}'),
                if (status.research.shortlisted > 0)
                  _InfoChip('Shortlist', '${status.research.shortlisted}'),
                if (status.research.securityReview > 0)
                  _InfoChip('Security review', '${status.research.securityReview}'),
                if (status.certifiedDeprecated > 0)
                  _InfoChip('Deprecated', '${status.certifiedDeprecated}'),
                if (status.revoked > 0)
                  _InfoChip('Revocati', '${status.revoked}'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Target: ${status.targets.join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
            if (!status.research.available) ...[
              const SizedBox(height: 8),
              Text(
                'Stato Researcher non disponibile: i conteggi certificati restano comunque autoritativi dalla Library.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label: $value'));
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.error,
    required this.onRetry,
  });

  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            const Text('Impossibile caricare lo stato dei moduli.'),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => unawaited(onRetry()),
              icon: const Icon(Icons.refresh),
              label: const Text('Riprova'),
            ),
          ],
        ),
      ),
    );
  }
}
