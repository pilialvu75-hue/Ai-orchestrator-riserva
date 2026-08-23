import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_manifest.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';

/// Prima schermata operativa del Cantiere.
///
/// La pagina rimane una UI sottile:
///
///   UI
///    ↓
///   WorkshopDashboardController
///    ↓
///   WorkshopEngine / Workshop toolchain
///
/// La pagina non contiene logica di esecuzione del progetto.
class WorkshopDashboardPage extends StatefulWidget {
  const WorkshopDashboardPage({
    super.key,
    WorkshopAppEmissionController? emissionController,
    WorkshopDashboardController? dashboardController,
  })  : _emissionController = emissionController,
        _dashboardController = dashboardController;

  final WorkshopAppEmissionController? _emissionController;
  final WorkshopDashboardController? _dashboardController;

  @override
  State<WorkshopDashboardPage> createState() =>
      _WorkshopDashboardPageState();
}

class _WorkshopDashboardPageState
    extends State<WorkshopDashboardPage> {
  late final WorkshopAppEmissionController _emissionController;
  late final WorkshopDashboardController?
      _dashboardController;

  bool get _ownsDashboardController =>
      widget._dashboardController != null;

  @override
  void initState() {
    super.initState();

    _emissionController =
        widget._emissionController ??
        WorkshopAppEmissionController();

    _dashboardController =
        widget._dashboardController;

    _dashboardController?.addListener(
      _onDashboardChanged,
    );
  }

  @override
  void dispose() {
    _dashboardController?.removeListener(
      _onDashboardChanged,
    );

    if (_ownsDashboardController) {
      _dashboardController?.dispose();
    }

    super.dispose();
  }

  void _onDashboardChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  void _refresh() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  Future<void> _startProduction() async {
    final controller = _dashboardController;

    if (controller == null) {
      _showMessage(
        'Il controller del Cantiere non è stato collegato.',
      );
      return;
    }

    final result =
        await showDialog<_WorkshopProductionInput>(
      context: context,
      builder: (context) =>
          const _WorkshopProductionDialog(),
    );

    if (!mounted || result == null) {
      return;
    }

    try {
      controller.startProduction(
        title: result.title,
        instruction: result.instruction,
      );

      if (!mounted) {
        return;
      }

      setState(() {});

      _showMessage(
        'Produzione preparata nel Cantiere.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      _showMessage(
        'Impossibile preparare la produzione: $error',
      );
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = _emissionController.state;

    final packages = _emissionController.recent(
      limit: 20,
    );

    final dashboardState =
        _dashboardController?.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cantiere'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Aggiorna',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _refresh();
        },
        child: ListView(
          physics:
              const AlwaysScrollableScrollPhysics(),
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
            if (dashboardState != null)
              _WorkshopProductionStatusCard(
                state: dashboardState,
              ),
            if (dashboardState != null)
              const SizedBox(height: 16),
            _WorkshopActionsCard(
              onRefresh: _refresh,
              onNewProduction: _startProduction,
              controllerConnected:
                  _dashboardController != null,
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
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'App Factory',
          style:
              theme.textTheme.headlineMedium?.copyWith(
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

class _WorkshopStatusCard
    extends StatelessWidget {
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
              backgroundColor:
                  color.withValues(alpha: 0.12),
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
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    state.hasEmittedApp
                        ? 'Cantiere operativo'
                        : 'Cantiere pronto',
                    style: theme
                        .textTheme.titleMedium
                        ?.copyWith(
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

class _WorkshopProductionStatusCard
    extends StatelessWidget {
  const _WorkshopProductionStatusCard({
    required this.state,
  });

  final WorkshopDashboardControllerState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final progress =
        state.progress.clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.engineering_outlined,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.projectTitle ??
                        'Produzione Cantiere',
                    style: theme
                        .textTheme.titleMedium
                        ?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (state.isBusy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress,
            ),
            const SizedBox(height: 8),
            Text(
              '${state.completedTasks}/'
              '${state.totalTasks} task completati',
            ),
            if (state.activeTaskTitle != null) ...[
              const SizedBox(height: 6),
              Text(
                'Task: ${state.activeTaskTitle}',
              ),
            ],
            if (state.lastMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                state.lastMessage!,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (state.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                state.lastError!,
                style: TextStyle(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkshopActionsCard
    extends StatelessWidget {
  const _WorkshopActionsCard({
    required this.onRefresh,
    required this.onNewProduction,
    required this.controllerConnected,
  });

  final VoidCallback onRefresh;
  final VoidCallback onNewProduction;
  final bool controllerConnected;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
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
              label: const Text(
                'Aggiorna stato',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: controllerConnected
                  ? onNewProduction
                  : null,
              icon: const Icon(
                Icons.play_arrow,
              ),
              label: const Text(
                'Nuova produzione',
              ),
            ),
            if (!controllerConnected) ...[
              const SizedBox(height: 8),
              Text(
                'Controller Cantiere non collegato.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkshopProductionDialog
    extends StatefulWidget {
  const _WorkshopProductionDialog();

  @override
  State<_WorkshopProductionDialog> createState() =>
      _WorkshopProductionDialogState();
}

class _WorkshopProductionDialogState
    extends State<_WorkshopProductionDialog> {
  final TextEditingController _titleController =
      TextEditingController();

  final TextEditingController
      _instructionController =
      TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _instructionController.dispose();
    super.dispose();
  }

  void _submit() {
    final title =
        _titleController.text.trim();
    final instruction =
        _instructionController.text.trim();

    if (title.isEmpty ||
        instruction.isEmpty) {
      return;
    }

    Navigator.of(context).pop(
      _WorkshopProductionInput(
        title: title,
        instruction: instruction,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit =
        _titleController.text.trim().isNotEmpty &&
        _instructionController.text
            .trim()
            .isNotEmpty;

    return AlertDialog(
      title: const Text(
        'Nuova produzione',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _titleController,
              textInputAction:
                  TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Nome progetto',
                hintText:
                    'La mia prima app',
              ),
              onChanged: (_) {
                setState(() {});
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller:
                  _instructionController,
              minLines: 4,
              maxLines: 8,
              decoration:
                  const InputDecoration(
                labelText: 'Cosa vuoi produrre?',
                hintText:
                    'Descrivi brevemente l’app da creare.',
                alignLabelWithHint: true,
              ),
              onChanged: (_) {
                setState(() {});
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed:
              canSubmit ? _submit : null,
          child: const Text(
            'Prepara produzione',
          ),
        ),
      ],
    );
  }
}

class _WorkshopProductionInput {
  const _WorkshopProductionInput({
    required this.title,
    required this.instruction,
  });

  final String title;
  final String instruction;
}

class _WorkshopSectionTitle
    extends StatelessWidget {
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
            style:
                theme.textTheme.titleLarge?.copyWith(
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

class _WorkshopEmptyState
    extends StatelessWidget {
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
              color: Theme.of(context)
                  .colorScheme
                  .primary,
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
              'Le prime applicazioni prodotte dal '
              'Cantiere appariranno qui.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopEmissionCard
    extends StatelessWidget {
  const _WorkshopEmissionCard({
    required this.package,
  });

  final WorkshopAppEmissionPackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final manifest =
        WorkshopAppEmissionManifest.fromPackage(
      package,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
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
                    package.appName
                                ?.trim()
                                .isNotEmpty ==
                            true
                        ? package.appName!
                        : 'Applicazione senza nome',
                    style: theme
                        .textTheme.titleMedium
                        ?.copyWith(
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
              package.message ??
                  'Artifact pronto.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopInfoRow
    extends StatelessWidget {
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
        crossAxisAlignment:
            CrossAxisAlignment.start,
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

class _WorkshopDiagnosticsCard
    extends StatelessWidget {
  const _WorkshopDiagnosticsCard({
    required this.controller,
  });

  final WorkshopAppEmissionController
      controller;

  @override
  Widget build(BuildContext context) {
    final diagnostics =
        controller.diagnostics();

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
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: diagnostics.entries
                  .map(
                    (entry) =>
                        _WorkshopInfoRow(
                      label: entry.key,
                      value:
                          _formatDiagnosticValue(
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

  String _formatDiagnosticValue(
    Object? value,
  ) {
    if (value == null) {
      return '—';
    }

    return value.toString();
  }
}
