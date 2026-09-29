import 'dart:async';

import 'package:ai_orchestrator/features/module_library/data/module_lab_github_actions_source.dart';
import 'package:flutter/material.dart';

class ModuleLabPage extends StatefulWidget {
  const ModuleLabPage({super.key, required this.source});
  final ModuleLabGitHubActionsSource source;
  @override
  State<ModuleLabPage> createState() => _ModuleLabPageState();
}

class _ModuleLabPageState extends State<ModuleLabPage> {
  Timer? _timer;
  ModuleLabRunStatus? _run;
  String? _error;
  bool _loading = true;
  bool _dispatching = false;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      if (_run?.running ?? false) unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  Future<void> _refresh() async {
    try {
      final run = await widget.source.latestResearcherRun();
      if (!mounted) return;
      setState(() { _run = run; _error = null; _loading = false; _now = DateTime.now(); });
    } catch (error) {
      if (!mounted) return;
      setState(() { _error = error.toString(); _loading = false; });
    }
  }

  Future<void> _dispatch() async {
    if (_dispatching) return;
    setState(() { _dispatching = true; _error = null; });
    try {
      await widget.source.dispatchResearcher();
      await Future<void>.delayed(const Duration(seconds: 2));
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _dispatching = false);
    }
  }

  DateTime _nextResearcherRun(DateTime now) {
    final utc = now.toUtc();
    for (final hour in const <int>[0, 6, 12, 18]) {
      final candidate = DateTime.utc(utc.year, utc.month, utc.day, hour, 17);
      if (candidate.isAfter(utc)) return candidate.toLocal();
    }
    return DateTime.utc(utc.year, utc.month, utc.day + 1, 0, 17).toLocal();
  }

  DateTime _nextMonthlyReset(DateTime now) {
    final utc = now.toUtc();
    return DateTime.utc(utc.year, utc.month + 1, 1).toLocal();
  }

  String _remaining(Duration value) {
    if (value.isNegative) return 'ora';
    final days = value.inDays;
    final hours = value.inHours.remainder(24);
    final minutes = value.inMinutes.remainder(60);
    if (days > 0) return days.toString() + 'g ' + hours.toString() + 'h ' + minutes.toString() + 'm';
    if (hours > 0) return hours.toString() + 'h ' + minutes.toString() + 'm';
    return minutes.toString() + 'm';
  }

  @override
  Widget build(BuildContext context) {
    final nextRun = _nextResearcherRun(_now);
    final reset = _nextMonthlyReset(_now);
    final runLabel = _run == null ? 'Ultimo run: non disponibile' :
        'Ultimo run #' + _run!.id.toString() + ': ' +
        (_run!.running ? _run!.status : (_run!.conclusion ?? 'completed'));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moduli — Lab'),
        actions: [IconButton(tooltip: 'Aggiorna', onPressed: _loading ? null : () => unawaited(_refresh()), icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Researcher', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Prossimo ciclo automatico tra ' + _remaining(nextRun.difference(_now))),
              const SizedBox(height: 8),
              if (_loading) const LinearProgressIndicator() else Text(runLabel),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton.icon(
                onPressed: _dispatching || (_run?.running ?? false) ? null : () => unawaited(_dispatch()),
                icon: _dispatching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
                label: Text((_run?.running ?? false) ? 'Researcher in esecuzione' : 'Avvia Researcher ora'),
              )),
            ]),
          )),
          const SizedBox(height: 12),
          Card(child: ListTile(
            leading: const Icon(Icons.timelapse),
            title: const Text('Reset mensile risorse'),
            subtitle: Text('Prossimo in ' + _remaining(reset.difference(_now)) + '. Saldo minuti non mostrato finché non è disponibile una fonte autorevole.'),
          )),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)))),
          ],
          const SizedBox(height: 12),
          Text('Lab di sviluppo: i comandi non modificano direttamente lo stato di certificazione della Module Library.', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
