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
        try {
          final state = await _output.refreshReadAloud();
          if (_text == null) return;
          final playing = state.playing;
          final busy = _busy && state.buffered == Duration.zero &&
              !state.complete;
          if (state.position != _playback.position ||
              state.buffered != _playback.buffered ||
              state.complete != _playback.complete ||
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

  Future<void> play(String text) {
    if (text.trim().isEmpty) return Future<void>.value();
    final token = ++_generation;
    _text = text;
    _playback = const ReadAloudSnapshot();
    _busy = true;
    notifyListeners();
    _watch();
    return _perform(token, () => _output.speak(text));
  }

  Future<void> stop() {
    if (_text == null) return Future<void>.value();
    final token = ++_generation;
    _busy = true;
    notifyListeners();
    return _perform(token, _output.stopSpeaking);
  }

  Future<void> restart() {
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
