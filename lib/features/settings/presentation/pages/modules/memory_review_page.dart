import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:flutter/material.dart';

/// Only reviews local, user-stated candidates. Does not collect any memory.
class MemoryReviewPage extends StatefulWidget {
  const MemoryReviewPage({super.key, required this.captureService});

  final AssistantDurableMemoryCaptureService captureService;

  @override
  State<MemoryReviewPage> createState() => _MemoryReviewPageState();
}

class _MemoryReviewPageState extends State<MemoryReviewPage> {
  List<AssistantDurableMemoryRecord> _pending =
      const <AssistantDurableMemoryRecord>[];
  bool _loading = true;
  bool _acting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records =
          await widget.captureService.loadReviewablePreferenceCandidates();
      if (!mounted) return;
      setState(() => _pending = records);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Impossibile leggere le proposte locali.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirm({
    required String heading,
    required String explanation,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(heading),
            content: Text(explanation),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Annulla'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(action),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<String?> _edit(AssistantDurableMemoryRecord record) async {
    final controller = TextEditingController(text: record.content);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Correggi la proposta'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Puoi correggere soltanto la preferenza proposta. '
                'La modifica verrà verificata prima di essere salvata.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('memory-review-edit-field'),
                controller: controller,
                maxLength: 110,
                maxLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Preferenza corretta',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Conferma correzione'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _review(
    AssistantDurableMemoryRecord record, {
    required bool approve,
    bool edit = false,
  }) async {
    if (_acting || _loading) return;
    String? correction;

    if (edit) {
      correction = await _edit(record);
      if (!mounted || correction == null) return;
    } else {
      final accepted = await _confirm(
        heading: approve ? 'Confermare il ricordo?' : 'Scartare la proposta?',
        explanation: record.content,
        action: approve ? 'Approva' : 'Scarta',
      );
      if (!mounted || !accepted) return;
    }

    setState(() => _acting = true);
    bool updated = false;
    try {
      updated = await widget.captureService.reviewUserPreferenceCandidate(
        reviewed: record,
        approve: approve,
        correctedContent: correction,
        userConfirmed: true,
      );
    } on Object {
      updated = false;
    } finally {
      if (mounted) setState(() => _acting = false);
    }
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          updated
              ? (approve ? 'Ricordo confermato.' : 'Proposta scartata.')
              : 'Proposta non modificata: contenuto non valido, '
                  'già cambiato oppure memoria non disponibile.',
        ),
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Proposte di memoria'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna le proposte',
            onPressed: _acting || _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'I suggerimenti non vengono usati nelle risposte finché '
              'non li approvi. La raccolta automatica non è attiva. '
              'Questa schermata riguarda soltanto la memoria locale '
              'di questo dispositivo.',
            ),
            const SizedBox(height: 18),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Column(
                children: [
                  Text(_error!, key: const Key('memory-review-error')),
                  TextButton(
                    onPressed: _refresh,
                    child: const Text('Riprova'),
                  ),
                ],
              )
            else if (_pending.isEmpty)
              const ListTile(
                key: Key('memory-review-empty'),
                leading: Icon(Icons.check_circle_outline),
                title: Text('Nessuna proposta da controllare'),
                subtitle: Text(
                  'Non significa che sia attiva la raccolta automatica.',
                ),
              )
            else
              for (final record in _pending)
                Card(
                  key: ValueKey<String>('memory-review-${record.recordKey}'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'In attesa di conferma',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(record.content),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            FilledButton.tonal(
                              onPressed: _acting
                                  ? null
                                  : () => _review(record, approve: true),
                              child: const Text('Approva'),
                            ),
                            OutlinedButton(
                              onPressed: _acting
                                  ? null
                                  : () => _review(
                                        record,
                                        approve: true,
                                        edit: true,
                                      ),
                              child: const Text('Correggi'),
                            ),
                            TextButton(
                              onPressed: _acting
                                  ? null
                                  : () => _review(record, approve: false),
                              child: const Text('Scarta'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
