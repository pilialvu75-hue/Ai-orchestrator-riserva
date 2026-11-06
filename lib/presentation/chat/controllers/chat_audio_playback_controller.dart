import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
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

  bool get isOpen => _text != null;
  bool get isPlaying => _playing;
  bool get isBusy => _busy;

  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_text == null) {
        _poll?.cancel();
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
    _busy = false;
    notifyListeners();
  }

  Future<void> play(String text) {
    if (text.trim().isEmpty) return Future<void>.value();
    final token = ++_generation;
    _text = text;
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

  void close() {
    if (_text == null) return;
    ++_generation;
    _text = null;
    _poll?.cancel();
    _playing = false;
    _busy = false;
    notifyListeners();
    unawaited(_output.stopSpeaking().catchError((Object _) {}));
  }
}
