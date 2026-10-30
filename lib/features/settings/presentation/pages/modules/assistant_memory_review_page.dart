import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:flutter/material.dart';

/// Explicit, developer-only preview for reviewing local memory proposals.
///
/// No implicit chat capture, telemetry, network access or automatic approvals.
/// The caller must only expose this page on a trusted single-user device;
/// account-aware owner isolation is a separate release gate.
class AssistantMemoryReviewPage extends StatefulWidget {
  const AssistantMemoryReviewPage({
    super.key,
    required this.captureService,
  });

  final AssistantDurableMemoryCaptureService captureService;

  @override
  State<AssistantMemoryReviewPage> createState() =>
      _AssistantMemoryReviewPageState();
}

class _AssistantMemoryReviewPageState extends State<AssistantMemoryReviewPage> {
  final TextEditingController _text = TextEditingController();
  List<AssistantDurableMemoryRecord> _pending =
      const <AssistantDurableMemoryRecord>[];
  bool _loading = true;
  bool _busy = false;
  bool _manualConsent = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final pending =
          await widget.captureService.loadReviewablePreferenceCandidates();
      if (!mounted) return;
      setState(() => _pending = pending);
    } on Object catch (_) {
      _message('Impossibile leggere le proposte locali.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _propose() async {
    if (_busy || !_manualConsent) return;
    setState(() => _busy = true);
    try {
      final ok = await widget.captureService.proposeUserPreferenceCandidate(
        userPrompt: _text.text,
        consentEnabled: true,
      );
      if (!mounted) return;
      if (ok) {
        _text.clear();
        setState(() => _manualConsent = false);
        _message('Proposta salvata solo per revisione.');
      } else {
        _message('Frase non riconosciuta: nessun ricordo salvato.');
      }
      await _refresh();
    } on Object catch (_) {
      _message('Salvataggio della proposta non riuscito.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _edit(AssistantDurableMemoryRecord record) {
    // Use the field's own lifecycle instead of disposing a controller while
    // the dialog dismissal animation may still be rendering its last frame.
    var proposed = record.content;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Correggi la proposta'),
        content: TextFormField(
          initialValue: record.content,
          onChanged: (value) => proposed = value,
          maxLines: 2,
          maxLength: 110,
          decoration: const InputDecoration(
            helperText: 'Sono ammesse solo preferenze sulle risposte.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, proposed.trim()),
            child: const Text('Continua'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(
    AssistantDurableMemoryRecord record, {
    required bool approve,
    String? correctedContent,
  }) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(approve ? 'Confermi il ricordo?' : 'Scartare la proposta?'),
        content: Text(
          approve
              ? (correctedContent ?? record.content)
              : 'Questa proposta verrà eliminata, senza toccare altri ricordi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(approve ? 'Conferma' : 'Scarta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final changed = await widget.captureService.reviewUserPreferenceCandidate(
        reviewed: record,
        approve: approve,
        userConfirmed: true,
        correctedContent: correctedContent,
      );
      if (!mounted) return;
      _message(changed
          ? (approve ? 'Ricordo confermato.' : 'Proposta scartata.')
          : 'La proposta è cambiata: ricarica prima di decidere.');
      await _refresh();
    } on Object catch (_) {
      _message('Operazione non completata: nessun esito confermato.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revisione memoria (test)')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Anteprima sviluppatore, soltanto su questo dispositivo. '
              'Nessuna conversazione viene analizzata automaticamente. '
              'Le proposte non sono usate nelle risposte finché non le confermi.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Prova manuale facoltativa',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              enabled: !_busy,
              maxLength: 110,
              decoration: const InputDecoration(
                labelText: 'La tua preferenza',
                hintText: 'Preferisco risposte brevi',
                border: OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              value: _manualConsent,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _manualConsent = v ?? false),
              title: const Text('Autorizzo questa singola proposta di prova'),
              subtitle: const Text(
                'Il consenso non rimane attivo per le prossime proposte.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            FilledButton(
              onPressed: _busy || !_manualConsent ? null : _propose,
              child: const Text('Proponi per revisione'),
            ),
            const Divider(height: 32),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Ricordi proposti',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: _busy || _loading ? null : _refresh,
                  tooltip: 'Aggiorna proposte',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_pending.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Nessuna proposta in attesa.'),
              )
            else
              for (final record in _pending)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(record.content),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _resolve(record, approve: true),
                              child: const Text('Approva'),
                            ),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final corrected = await _edit(record);
                                      if (corrected == null || !mounted) return;
                                      await _resolve(
                                        record,
                                        approve: true,
                                        correctedContent: corrected,
                                      );
                                    },
                              child: const Text('Correggi'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _resolve(record, approve: false),
                              child: const Text('Scarta'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 12),
            const Text(
              'Il test usa solo la memoria SQLite locale. '
              'Il reset selettivo è disponibile nella Danger Zone. '
              'Non abilitare questa anteprima su dispositivi condivisi.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
