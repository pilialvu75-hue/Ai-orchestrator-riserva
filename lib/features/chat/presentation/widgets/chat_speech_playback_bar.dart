import 'package:ai_orchestrator/features/chat/presentation/controllers/chat_speech_playback_controller.dart';
import 'package:flutter/material.dart';

/// Compact real playback controls shown above the composer after Ascolta.
class ChatSpeechPlaybackBar extends StatelessWidget {
  const ChatSpeechPlaybackBar({super.key, required this.controller});
  final ChatSpeechPlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final active = state == SpeechPlaybackState.playing ||
        state == SpeechPlaybackState.preparing;
    final label = switch (state) {
      SpeechPlaybackState.preparing => 'Preparazione audio',
      SpeechPlaybackState.paused => 'In pausa',
      SpeechPlaybackState.stopped => 'Interrotto',
      SpeechPlaybackState.finished => 'Ascolto terminato',
      SpeechPlaybackState.error => 'Audio non disponibile',
      _ => 'Ascolto del messaggio',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF202C3F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq_rounded,
              color: Color(0xFF8AB4F8), size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
                Text('Frase ' + controller.phraseNumber.toString() +
                    ' di ' + controller.phraseCount.toString(),
                    style: const TextStyle(color: Colors.white60, fontSize: 10)),
              ],
            ),
          ),
          _action('Torna indietro di una frase', Icons.replay_rounded,
              state == SpeechPlaybackState.preparing ? null : controller.previous),
          _action(
            active ? 'Pausa' : 'Riprendi dalla frase',
            active ? Icons.pause_rounded : Icons.play_arrow_rounded,
            active ? controller.pause : controller.resume,
          ),
          _action('Frase successiva', Icons.skip_next_rounded,
              controller.phraseNumber < controller.phraseCount
                  ? controller.next : null),
          _action('Interrompi', Icons.stop_rounded, controller.stop),
          _action('Chiudi ascolto', Icons.close_rounded, controller.close),
        ],
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback? pressed) {
    return IconButton(
      tooltip: label,
      onPressed: pressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 40),
      iconSize: 19,
      color: const Color(0xFFD5E3F9),
      icon: Icon(icon),
    );
  }
}
