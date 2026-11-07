import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/core/voice/read_aloud_transport.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;
import 'package:flutter/foundation.dart';

/// Read-aloud state lives independently from any chat route.
/// Background playback across other Android applications additionally
/// requires a platform mediaPlayback foreground service.
class ChatAudioPlaybackController extends ChangeNotifier {
  ChatAudioPlaybackController({VoiceOutputService? output})
      : _output = output ?? di.sl<VoiceOutputService>();

  static final ChatAudioPlaybackController shared =
      ChatAudioPlaybackController();

  final VoiceOutputService _output;
  String? _text;
  bool _playing = false;
  bool _busy = false;
  int _generation = 0;
  Timer? _poll;
  bool _pollInFlight = false;
  ReadAloudSnapshot _playback = const ReadAloudSnapshot();
  String? _resumeBookmarkText;
  Duration _resumeBookmarkPosition = Duration.zero;

  void _clearBookmark() {
    _resumeBookmarkText = null;
    _resumeBookmarkPosition = Duration.zero;
  }

  void _rememberInterruptedPlayback(ReadAloudSnapshot stopped) {
    // The native service supplies the exact played-frame clock on permanent
    // audio focus loss. An explicit Stop, notification dismissal, or natural
    // completion must NEVER create a resume bookmark.
    final position = stopped.position > Duration.zero
        ? stopped.position : _playback.position;
    if (_text != null &&
        stopped.terminatedByFocusLoss &&
        position > Duration.zero &&
        (!_playback.complete ||
            _playback.position < _playback.buffered)) {
      _resumeBookmarkText = _text;
      _resumeBookmarkPosition = position;
    } else {
      _clearBookmark();
    }
  }

  bool get isOpen => _text != null;
  bool get isPlaying => _playing;
  bool get isBusy => _busy;
  bool get canSeek => _output.supportsRealReadAloudControls;
  bool get isPaused => _playback.paused;
  ReadAloudSnapshot get measuredPlayback => _playback;

  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_text == null) {
        _poll?.cancel();
        return;
      }
      if (canSeek) {
        if (_pollInFlight) return;
        _pollInFlight = true;
        final generationAtPoll = _generation;
        try {
          final state = await _output.refreshReadAloud();
          // A previous native status response must never overwrite a new
          // message's player state after a rapid chat switch.
          if (_text == null || generationAtPoll != _generation) return;
          // The Android foreground service closes itself after the final
          // played PCM frame (or after a permanent audio-focus loss).
          // Do not leave a dead "Riprendi" button that would target a
          // destroyed MediaSession. The message speaker can start a fresh
          // playback explicitly when the user wants to listen again.
          // Once an actual foreground session existed, losing it means
          // playback ended (including permanent audio-focus loss). This
          // also applies while Kokoro is still synthesizing: do not strand
          // the UI in "busy" with a dead media session after YouTube.
          if (!state.active && _playback.active) {
            _rememberInterruptedPlayback(state);
            ++_generation;
            _text = null;
            _poll?.cancel();
            _playback = const ReadAloudSnapshot();
            _playing = false;
            _busy = false;
            notifyListeners();
            return;
          }
          final playing = state.playing;
          final busy = state.rebuildingBookmark ||
              (_busy && state.buffered == Duration.zero && !state.complete);
          if (state.active != _playback.active ||
              state.position != _playback.position ||
              state.buffered != _playback.buffered ||
              state.complete != _playback.complete ||
              state.rebuildingBookmark != _playback.rebuildingBookmark ||
              state.paused != _playback.paused ||
              playing != _playing || busy != _busy) {
            _playback = state;
            _playing = playing;
            _busy = busy;
            notifyListeners();
          }
        } catch (error) {
          debugPrint('PCM playback status unavailable: $error');
        } finally {
          _pollInFlight = false;
        }
        return;
      }
      final speaking = _output.isSpeaking;
      if (!_busy && speaking != _playing) {
        _playing = speaking;
        notifyListeners();
      }
    });
  }

  Future<void> _perform(int token, Future<void> Function() operation) async {
    try {
      await operation();
      if (token != _generation) return;
      _playing = _output.isSpeaking;
    } catch (error) {
      debugPrint('TTS playback failed: $error');
      if (token != _generation) return;
      _playing = false;
    }
    if (canSeek) _playback = _output.readAloudSnapshot;
    _busy = false;
    notifyListeners();
  }

  Future<void> play(String text) async {
    if (text.trim().isEmpty) return;
    final token = ++_generation;

    // When returning from an external app, a suspended Flutter poller may
    // not have observed native MediaSession teardown yet. Take one fresh
    // status sample before starting a new user-requested session.
    if (canSeek && _text == text && _playback.active) {
      try {
        final native = await _output.refreshReadAloud();
        if (!native.active) _rememberInterruptedPlayback(native);
      } catch (error) {
        debugPrint('PCM bookmark preflight unavailable: $error');
      }
    }

    // A second tap can supersede an in-flight native status preflight.
    if (token != _generation) return;
    final bookmark = _resumeBookmarkText == text
        ? _resumeBookmarkPosition : Duration.zero;
    _clearBookmark(); // Never seek a different message to an old position.
    _text = text;
    _playback = const ReadAloudSnapshot();
    _busy = true;
    notifyListeners();
    _watch();
    await _perform(token, () => bookmark > Duration.zero && canSeek
        ? _output.speakFromPosition(text, bookmark)
        : _output.speak(text));
  }

  Future<void> stop() {
    _clearBookmark();
    if (_text == null) return Future<void>.value();
    final token = ++_generation;
    _busy = true;
    notifyListeners();
    return _perform(token, _output.stopSpeaking);
  }

  Future<void> restart() {
    _clearBookmark(); // Explicit Restart always means from the beginning.
    final text = _text;
    if (text == null) return Future<void>.value();
    final token = ++_generation;
    _busy = true;
    notifyListeners();
    return _perform(token, () async {
      await _output.stopSpeaking();
      await _output.speak(text);
    });
  }

  Future<void> pause() async {
    if (!canSeek || _text == null || _busy) return;
    await _output.pauseReadAloud();
    _playback = await _output.refreshReadAloud();
    _playing = _playback.playing;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!canSeek || _text == null || _busy) return;
    await _output.resumeReadAloud();
    _playback = await _output.refreshReadAloud();
    _playing = _playback.playing;
    notifyListeners();
  }

  Future<void> skip(Duration offset) async {
    if (!canSeek || _text == null || _busy) return;
    await _output.skipReadAloud(offset);
    _playback = await _output.refreshReadAloud();
    _playing = _playback.playing;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    if (!canSeek || _text == null || _busy) return;
    await _output.seekReadAloud(position);
    _playback = await _output.refreshReadAloud();
    _playing = _playback.playing;
    notifyListeners();
  }

  void close() {
    _clearBookmark();
    if (_text == null) return;
    ++_generation;
    _text = null;
    _poll?.cancel();
    _playback = const ReadAloudSnapshot();
    _playing = false;
    _busy = false;
    notifyListeners();
    unawaited(_output.stopSpeaking().catchError((Object _) {}));
  }
}
