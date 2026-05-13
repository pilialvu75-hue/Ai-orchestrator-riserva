import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/voice/voice_input_service.dart';

/// Floating mic button that toggles speech-to-text recording.
///
/// While recording, the button pulses and shows a waveform-like animation.
/// The recognised text is delivered via [onResult] callbacks.
class VoiceInputButton extends StatefulWidget {
  const VoiceInputButton({
    super.key,
    required this.voiceInputService,
    required this.onResult,
    this.size = 56,
  });

  final VoiceInputService voiceInputService;

  /// Called with each recognised phrase. [isFinal] is `true` on the final
  /// result for the current utterance.
  final void Function(String text, bool isFinal) onResult;

  /// Diameter of the button in logical pixels.
  final double size;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton>
    with SingleTickerProviderStateMixin {
  bool _listening = false;
  late AnimationController _pulse;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await widget.voiceInputService.stopListening();
      _pulse.stop();
      setState(() => _listening = false);
    } else {
      await widget.voiceInputService.startListening(
        onResult: (text, isFinal) {
          widget.onResult(text, isFinal);
          if (isFinal) {
            _pulse.stop();
            if (mounted) setState(() => _listening = false);
          }
        },
      );
      final started = widget.voiceInputService.isListening;
      if (started) {
        _pulse.repeat(reverse: true);
      } else {
        _pulse.stop();
      }
      setState(() => _listening = started);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _listening
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return ScaleTransition(
      scale: _listening ? _scale : const AlwaysStoppedAnimation(1.0),
      child: SizedBox.square(
        dimension: widget.size,
        child: FloatingActionButton(
          heroTag: 'voice_input_btn',
          backgroundColor: color,
          foregroundColor: Colors.white,
          onPressed: _toggle,
          tooltip: _listening ? 'Stop recording' : 'Start voice input',
          child: Icon(_listening ? Icons.mic_off : Icons.mic),
        ),
      ),
    );
  }
}
