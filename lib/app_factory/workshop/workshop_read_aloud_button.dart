import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/injection_container.dart';

/// Uses the same lazy TTS service as Assistant; never owns its native engine.
class WorkshopReadAloudButton extends StatefulWidget {
  const WorkshopReadAloudButton({super.key, required this.text, this.read});
  final String text;
  final Future<void> Function(String)? read;

  @override
  State<WorkshopReadAloudButton> createState() => _WorkshopReadAloudButtonState();
}

class _WorkshopReadAloudButtonState extends State<WorkshopReadAloudButton>
    with RuntimeEventEmitter {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy || widget.text.trim().isEmpty) return;
    setState(() => _busy = true);
    logEvent('VOICE_ENGINE', '[VOICE_ICON_TAP] origin=workshop');
    try {
      final read = widget.read;
      if (read != null) {
        await read(widget.text);
      } else {
        final output = sl<VoiceOutputService>();
        await output.speak(widget.text);
        if (output.lastStatus?.offlineTtsAvailable == false) {
          throw StateError('Scarica Kokoro dal menu dei modelli vocali.');
        }
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lettura vocale non disponibile: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: _busy ? 'Preparazione della voce…' : 'Leggi / interrompi lettura',
        onPressed: _busy || widget.text.trim().isEmpty ? null : _toggle,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.volume_up_outlined),
      );
}
