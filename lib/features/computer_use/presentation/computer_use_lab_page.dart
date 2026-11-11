import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

/// Manual, local proof-of-life UI. No LLM is authorized to start a session.
/// A later agent loop can reuse ComputerUseSession after physical host QA.
class ComputerUseLabPage extends StatefulWidget {
  const ComputerUseLabPage({super.key});

  @override
  State<ComputerUseLabPage> createState() => _ComputerUseLabPageState();
}

class _ComputerUseLabPageState extends State<ComputerUseLabPage> {
  final ComputerUseSession _session = ComputerUseSession(
    adapter: WindowsComputerUseAdapter(),
  );
  final TextEditingController _textController = TextEditingController();

  Uint8List? _frame;
  int _frameWidth = 1;
  int _frameHeight = 1;
  bool _busy = false;
  String _message = 'Nessuna sessione attiva.';

  @override
  void dispose() {
    _session.stop();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _begin({required bool interactive}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Autorizzare Computer Use?'),
        content: Text(
          interactive
              ? 'Per 10 minuti Aivexus potra acquisire schermate e '
                'inviare clic o tasti sul desktop Windows. '
                'Non inserire password o dati sensibili durante il test.'
              : 'Per 10 minuti Aivexus potra acquisire schermate '
                'localmente, senza inviarle al Cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Autorizza'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      _session.beginSession(allowInteraction: interactive);
      await _refreshFrame();
      if (mounted) {
        setState(() => _message = interactive
            ? 'Interazione attiva: tocca una finestra nella schermata.'
            : 'Sola osservazione attiva.');
      }
    });
  }

  Future<void> _selectTargetWindow() async {
    await _run(() async {
      if (mounted) {
        setState(() => _message =
            'Passa ora alla finestra da controllare (4 secondi).');
      }
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_session.canInteract) return;
      final result = await _session.execute(<String, dynamic>{
        'action': 'select_window',
      });
      if (!result.success) {
        throw ComputerUseException(
          result.error ?? 'TARGET_NOT_FOUND',
          result.output,
        );
      }
      if (mounted) {
        setState(() => _message =
            'Finestra selezionata. Torna in Aivexus per inviare i comandi.');
      }
    });
  }

  Future<void> _refreshFrame() async {
    final bytes = await _session.captureFrame();
    final data = ByteData.sublistView(bytes);
    if (!mounted) return;
    setState(() {
      _frame = bytes;
      _frameWidth = data.getUint32(16);
      _frameHeight = data.getUint32(20);
    });
  }

  Future<void> _invoke(Map<String, dynamic> params) async {
    await _run(() async {
      final result = await _session.execute(params);
      if (!result.success) {
        throw ComputerUseException(
          result.error ?? 'ACTION_FAILED',
          result.output,
        );
      }
      if (_session.isActive) await _refreshFrame();
      if (mounted) setState(() => _message = result.output);
    });
  }

  Future<void> _click(TapUpDetails details, double width) async {
    if (!_session.canInteract || _busy) return;
    final x = (details.localPosition.dx * _frameWidth / width)
        .floor()
        .clamp(0, _frameWidth - 1);
    final y = (details.localPosition.dy * _frameWidth / width)
        .floor()
        .clamp(0, _frameHeight - 1);
    await _invoke(<String, dynamic>{'action': 'click', 'x': x, 'y': y});
  }

  void _stop() {
    _session.stop();
    setState(() {
      _frame = null;
      _message = 'Sessione interrotta.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _session.isActive;
    final interactive = _session.canInteract;
    return Scaffold(
      appBar: AppBar(title: const Text('Computer Use — Laboratorio')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Test Windows locale: schermata, clic, testo e navigazione. '
            'Nessuna esecuzione di shell o invio automatico di immagini.',
          ),
          const SizedBox(height: 12),
          if (!_session.isSupported)
            const Text('Computer Use Windows non disponibile qui.')
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: !_busy && !active
                      ? () => _begin(interactive: false)
                      : null,
                  child: const Text('Osserva schermo'),
                ),
                FilledButton(
                  onPressed: !_busy && !active
                      ? () => _begin(interactive: true)
                      : null,
                  child: const Text('Abilita interazione'),
                ),
                OutlinedButton(
                  onPressed: !_busy && active
                      ? () => _run(_refreshFrame)
                      : null,
                  child: const Text('Aggiorna'),
                ),
                OutlinedButton(
                  onPressed: active ? _stop : null,
                  child: const Text('STOP'),
                ),
              ],
            ),
            if (interactive) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke(<String, dynamic>{
                              'action': 'open_app',
                              'app': 'notepad',
                            }),
                    icon: const Icon(Icons.notes_outlined),
                    label: const Text('Apri Blocco note'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke(<String, dynamic>{
                              'action': 'open_app',
                              'app': 'calculator',
                            }),
                    icon: const Icon(Icons.calculate_outlined),
                    label: const Text('Apri Calcolatrice'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _selectTargetWindow,
                icon: const Icon(Icons.select_all_outlined),
                label: const Text('Seleziona finestra attiva (4 secondi)'),
              ),
              const Text(
                'Premi il pulsante, poi passa subito a Blocco note. '
                'La selezione non richiede password né privilegi elevati.',
              ),
            ],
            if (active && _session.expiresAt != null) ...[
              const SizedBox(height: 8),
              Text('Scadenza sessione: ${_session.expiresAt!.hour.toString().padLeft(2, '0')}:'
                  '${_session.expiresAt!.minute.toString().padLeft(2, '0')}'),
            ],
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            Text(_message),
            const SizedBox(height: 12),
            if (_frame != null && active)
              LayoutBuilder(
                builder: (context, box) => AspectRatio(
                  aspectRatio: _frameWidth / _frameHeight,
                  child: GestureDetector(
                    onTapUp: interactive && !_busy
                        ? (details) => _click(details, box.maxWidth)
                        : null,
                    child: Image.memory(
                      _frame!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
              ),
            if (interactive) ...[
              const SizedBox(height: 16),
              const Text('Seleziona prima la finestra da controllare. '
                  'Poi torna qui per inviare testo o tasti; '
                  'Aivexus riattiverà la finestra scelta.'),
              const SizedBox(height: 8),
              TextField(
                controller: _textController,
                onChanged: (_) => setState(() {}),
                maxLength: 512,
                decoration: const InputDecoration(
                  labelText: 'Testo da inserire nella finestra selezionata',
                  border: OutlineInputBorder(),
                ),
              ),
              FilledButton(
                onPressed: _busy || _textController.text.isEmpty
                    ? null
                    : () async {
                        final value = _textController.text;
                        await _invoke(<String, dynamic>{
                          'action': 'type_text',
                          'text': value,
                        });
                        if (mounted && _message ==
                            'Text entered into the active window.') {
                          _textController.clear();
                        }
                      },
                child: const Text('Inserisci testo'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final key in ComputerUseSession.allowedKeys.toList()
                      ..sort())
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _invoke(<String, dynamic>{
                                'action': 'press_key',
                                'key': key,
                              }),
                      child: Text(key),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
