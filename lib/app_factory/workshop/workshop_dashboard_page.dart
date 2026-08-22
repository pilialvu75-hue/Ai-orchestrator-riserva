import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_manifest.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';

/// Prima schermata operativa del Cantiere.
///
/// Questa pagina è volutamente autonoma:
///
/// - non avvia build;
/// - non modifica il progetto;
/// - non installa APK;
/// - non accede direttamente a GitHub;
/// - non interroga provider AI.
///
/// Visualizza invece ciò che il Cantiere ha già prodotto.
///
/// Questo permette di collegare progressivamente la UI ai
/// componenti reali senza introdurre side-effect durante il primo
/// passaggio di integrazione grafica.
class WorkshopDashboardPage extends StatefulWidget {
  const WorkshopDashboardPage({
    super.key,
    WorkshopAppEmissionController? emissionController,
  }) : _emissionController = emissionController;

  final WorkshopAppEmissionController? _emissionController;

  @override
  State<WorkshopDashboardPage> createState() =>
      _WorkshopDashboardPageState();
}

class _WorkshopDashboardPageState
    extends State<WorkshopDashboardPage> {
  late final WorkshopAppEmissionController _emissionController;

  @override
  void initState() {
    super.initState();

    _emissionController =
        widget._emissionController ??
        WorkshopAppEmissionController();
  }

  @override
  Widget build(BuildContext context) {
    final state = _emissionController.state;

    final packages = _emissionController.recent(
      limit: 20,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cantiere'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Aggiorna',
            onPressed: () {
              setState(() {});
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() {});
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _WorkshopHeader(
              state: state,
            ),
            const SizedBox(height: 16),
            _WorkshopStatusCard(
              state: state,
            ),
            const SizedBox(height: 16),
            _WorkshopActionsCard(
              onRefresh: () {
                setState(() {});
              },
            ),
            const SizedBox(height: 24),
            _WorkshopSectionTitle(
              title: 'App emesse',
              count: packages.length,
            ),
            const SizedBox(height: 8),
            if (packages.isEmpty)
              const _WorkshopEmptyState()
            else
              ...packages.map(
                (package) => Padding(
                  padding: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  child: _WorkshopEmissionCard(
                    package: package,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            _WorkshopDiagnosticsCard(
              controller: _emissionController,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopHeader extends StatelessWidget {
  const _WorkshopHeader({
    required this.state,
  });

  final WorkshopAppEmissionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'App Factory',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          state.hasEmittedApp
              ? 'Il Cantiere ha già prodotto applicazioni.'
              : 'Il Cantiere è pronto per iniziare la produzione.',
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }
}

class _WorkshopStatusCard extends StatelessWidget {
  const _WorkshopStatusCard({
    required this.state,
  });

  final WorkshopAppEmissionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final color = state.hasEmittedApp
        ? Colors.green
        : theme.colorScheme.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              backgroundColor: color.withValues(
                alpha: 0.12,
              ),
              child: Icon(
                state.hasEmittedApp
                    ? Icons.check_circle
                    : Icons.construction,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    state.hasEmittedApp
                        ? 'Cantiere operativo'
                        : 'Cantiere pronto',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${state.readyPackages} app pronte · '
                    '${state.totalPackages} pacchetti registrati',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopActionsCard extends StatelessWidget {
  const _WorkshopActionsCard({
    required this.onRefresh,
  });

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Cantiere',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Aggiorna stato'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      "L'esecuzione reale verrà collegata al prossimo anello.",
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Nuova produzione'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopSectionTitle extends StatelessWidget {
  const _WorkshopSectionTitle({
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (count > 0)
          Chip(
            label: Text('$count'),
          ),
      ],
    );
  }
}

class _WorkshopEmptyState extends StatelessWidget {
  const _WorkshopEmptyState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Icon(
              Icons.inventory_2_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Nessuna app emessa',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Le prime applicazioni prodotte dal Cantiere appariranno qui.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopEmissionCard extends StatelessWidget {
  const _WorkshopEmissionCard({
    required this.package,
  });

  final WorkshopAppEmissionPackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final manifest = WorkshopAppEmissionManifest.fromPackage(
      package,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  child: Icon(
                    manifest.isReady
                        ? Icons.check
                        : Icons.warning,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    package.appName?.trim().isNotEmpty == true
                        ? package.appName!
                        : 'Applicazione senza nome',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _WorkshopInfoRow(
              label: 'Target',
              value: package.target,
            ),
            _WorkshopInfoRow(
              label: 'Versione',
              value: package.version ?? '—',
            ),
            _WorkshopInfoRow(
              label: 'Request',
              value: package.requestId,
            ),
            _WorkshopInfoRow(
              label: 'Artifact',
              value: package.artifactPath,
            ),
            const SizedBox(height: 8),
            Text(
              package.message ?? 'Artifact pronto.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopInfoRow extends StatelessWidget {
  const _WorkshopInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: 6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkshopDiagnosticsCard extends StatelessWidget {
  const _WorkshopDiagnosticsCard({
    required this.controller,
  });

  final WorkshopAppEmissionController controller;

  @override
  Widget build(BuildContext context) {
    final diagnostics = controller.diagnostics();

    return Card(
      child: ExpansionTile(
        leading: const Icon(
          Icons.bug_report_outlined,
        ),
        title: const Text(
          'Diagnostica Cantiere',
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: diagnostics.entries
                  .map(
                    (entry) => _WorkshopInfoRow(
                      label: entry.key,
                      value: _formatDiagnosticValue(
                        entry.value,
                      ),
                    ),
                  )
                  .toList(
                    growable: false,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDiagnosticValue(Object? value) {
    if (value == null) {
      return '—';
    }

    if (value is Map || value is List) {
      return value.toString();
    }

    return value.toString();
  }
}
