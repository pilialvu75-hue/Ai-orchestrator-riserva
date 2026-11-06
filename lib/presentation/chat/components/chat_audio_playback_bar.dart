import 'package:flutter/material.dart';

/// Compact mini-player: Android uses measured PCM play-head time and a real
/// draggable seek track; platforms still using mp_audio_stream retain the
/// explicitly decorative waveform and honest stop/restart controls.
/// Foreground MediaSession playback is a separate Android follow-up (#967).
class ChatAudioPlaybackBar extends StatelessWidget {
  const ChatAudioPlaybackBar({
    super.key,
    required this.isPlaying,
    required this.isBusy,
    required this.onStop,
    required this.onRestart,
    required this.onClose,
    this.realTransport = false,
    this.isPaused = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.complete = false,
    this.onPause,
    this.onResume,
    this.onBack,
    this.onForward,
    this.onSeek,
  });

  final bool isPlaying;
  final bool isBusy;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onClose;

  /// Only true when the native engine supplies measured playback positions.
  /// All other platforms retain the honest stop/restart fallback.
  final bool realTransport;
  final bool isPaused;
  final Duration position;
  final Duration buffered;
  final bool complete;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final ValueChanged<Duration>? onSeek;

  static String _format(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _realPlayer() {
    final limit = buffered.inMilliseconds;
    final canScrub = !isBusy && limit > 0;
    final current = position.inMilliseconds.clamp(0, limit > 0 ? limit : 0);
    final atEnd = complete && buffered > Duration.zero && position >= buffered;
    return Row(
      children: [
        IconButton(
          tooltip: isBusy
              ? 'Preparazione audio'
              : atEnd
                  ? 'Riascolta dall’inizio'
                  : isPaused || !isPlaying
                      ? 'Riprendi lettura'
                      : 'Pausa lettura',
          onPressed: isBusy
              ? null
              : atEnd
                  ? onRestart
                  : isPaused || !isPlaying
                      ? onResume
                      : onPause,
          icon: Icon(
            isBusy
                ? Icons.hourglass_top_rounded
                : isPaused || !isPlaying
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
            size: 25,
          ),
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            minimumSize: const Size(40, 40),
            maximumSize: const Size(40, 40),
          ),
        ),
        IconButton(
          tooltip: 'Indietro 10 secondi',
          onPressed: canScrub ? onBack : null,
          icon: const Icon(Icons.replay_10, size: 23),
          color: Colors.white,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
          padding: EdgeInsets.zero,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_format(position)} / ${_format(buffered)}'
                '${complete ? '' : ' · generato'}',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(
                height: 23,
                child: _MeasuredSeekSlider(
                  positionMs: current,
                  bufferedMs: limit,
                  enabled: canScrub,
                  onSeek: onSeek,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Avanti 10 secondi',
          onPressed: canScrub ? onForward : null,
          icon: const Icon(Icons.forward_10, size: 23),
          color: Colors.white,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
          padding: EdgeInsets.zero,
        ),
        IconButton(
          tooltip: 'Chiudi lettore',
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded, size: 23),
          color: Colors.white,
          constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

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
        child: realTransport ? _realPlayer() : Row(
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

/// Own state is stable across the 250-ms PCM clock refresh. A parent rebuild
/// cannot snap the thumb back while the user is dragging a long recording.
class _MeasuredSeekSlider extends StatefulWidget {
  const _MeasuredSeekSlider({
    required this.positionMs,
    required this.bufferedMs,
    required this.enabled,
    required this.onSeek,
  });

  final int positionMs;
  final int bufferedMs;
  final bool enabled;
  final ValueChanged<Duration>? onSeek;

  @override
  State<_MeasuredSeekSlider> createState() => _MeasuredSeekSliderState();
}

class _MeasuredSeekSliderState extends State<_MeasuredSeekSlider> {
  double? _draggingMs;

  @override
  Widget build(BuildContext context) {
    final max = widget.bufferedMs > 0
        ? widget.bufferedMs.toDouble()
        : 1.0;
    final value = (_draggingMs ?? widget.positionMs.toDouble())
        .clamp(0.0, max).toDouble();
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: SliderComponentShape.noOverlay,
      ),
      child: Slider(
        value: value,
        min: 0,
        max: max,
        onChanged: widget.enabled
            ? (value) => setState(() => _draggingMs = value)
            : null,
        onChangeEnd: widget.enabled
            ? (value) {
                setState(() => _draggingMs = null);
                widget.onSeek?.call(Duration(milliseconds: value.round()));
              }
            : null,
      ),
    );
  }
}
