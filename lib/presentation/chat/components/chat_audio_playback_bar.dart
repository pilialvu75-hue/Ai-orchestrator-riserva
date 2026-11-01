import 'package:flutter/material.dart';

/// Compact voice mini-player styled like a waveform pill.
/// The waveform is decorative: mp_audio_stream has no native seek/pause
/// API. Real time/progress will be added with the background media player.
class ChatAudioPlaybackBar extends StatelessWidget {
  const ChatAudioPlaybackBar({
    super.key,
    required this.isPlaying,
    required this.isBusy,
    required this.onStop,
    required this.onRestart,
    required this.onClose,
  });

  final bool isPlaying;
  final bool isBusy;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF303236),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: isBusy
                  ? 'Preparazione audio'
                  : isPlaying
                      ? 'Interrompi lettura'
                      : 'Riproduci dall’inizio',
              onPressed: isBusy ? null : (isPlaying ? onStop : onRestart),
              style: IconButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(42, 42),
                maximumSize: const Size(42, 42),
              ),
              icon: Icon(
                isBusy
                    ? Icons.hourglass_top_rounded
                    : isPlaying
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                size: 24,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 47,
              child: Text(
                isBusy ? 'Audio…' : isPlaying ? 'Ascolto' : 'Fermo',
                style: const TextStyle(color: Colors.white, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            const Expanded(child: _WaveformDecoration()),
            IconButton(
              tooltip: 'Ricomincia dall’inizio',
              onPressed: isBusy ? null : onRestart,
              icon: const Icon(Icons.replay_rounded, size: 19),
              color: Colors.white70,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
            IconButton(
              tooltip: 'Chiudi lettore',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 24),
              color: Colors.white,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
          ],
        ),
      ),
    );
  }
}

/// Decorative bars only, not measured audio samples or playback progress.
class _WaveformDecoration extends StatelessWidget {
  const _WaveformDecoration();
  static const heights = <double>[
    12, 26, 17, 30, 13, 23, 27, 15, 32, 18, 24, 12,
    27, 19, 31, 16, 23, 28, 14, 30, 20, 13, 26, 17,
  ];

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final height in heights)
            Flexible(
              child: Container(
                width: 2,
                height: height,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
