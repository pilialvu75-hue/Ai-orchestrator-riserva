import 'dart:async';

import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:flutter/foundation.dart';

enum SpeechPlaybackState { idle, preparing, playing, paused, stopped, finished, error }

/// Controls TTS at phrase boundaries. The native engine has no time seek or
/// exact pause API, so a resumed phrase restarts from that phrase's beginning.
class ChatSpeechPlaybackController extends ChangeNotifier {
  ChatSpeechPlaybackController(this._voice);
  final VoiceOutputService _voice;
  List<String> _phrases = const [];
  int _index = 0;
  int _generation = 0;
  int _silenceChecks = 0;
  Timer? _poller;
  SpeechPlaybackState _state = SpeechPlaybackState.idle;

  SpeechPlaybackState get state => _state;
  bool get visible => _state != SpeechPlaybackState.idle;
  int get phraseNumber => _phrases.isEmpty ? 0 : _index + 1;
  int get phraseCount => _phrases.length;

  static List<String> splitPhrases(String content) {
    final sentences = content.trim().split(RegExp(r'(?<=[.!?])\s+'));
    final result = <String>[];
    for (final sentence in sentences) {
      var rest = sentence.trim();
      while (rest.length > 240) {
        var split = rest.lastIndexOf(' ', 240);
        if (split < 40) split = 240;
        result.add(rest.substring(0, split).trim());
        rest = rest.substring(split).trim();
      }
      if (rest.isNotEmpty) result.add(rest);
    }
    return result;
  }

  void start(String content) {
    final phrases = splitPhrases(content);
    if (phrases.isEmpty) return;
    _phrases = phrases;
    _index = 0;
    _play();
  }

  void _play() {
    final token = ++_generation;
    _poller?.cancel();
    _silenceChecks = 0;
    _state = SpeechPlaybackState.preparing;
    notifyListeners();
    unawaited(_playAsync(token));
  }

  Future<void> _playAsync(int token) async {
    try {
      await _voice.stopSpeaking();
      if (token != _generation) return;
      await _voice.speak(_phrases[_index]);
      if (token != _generation) return;
      _state = SpeechPlaybackState.playing;
      notifyListeners();
      _poller = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (token != _generation) return;
        if (_voice.isSpeaking) {
          _silenceChecks = 0;
          return;
        }
        if (++_silenceChecks < 3) return;
        _poller?.cancel();
        if (_index + 1 < _phrases.length) {
          _index++;
          _play();
        } else {
          _state = SpeechPlaybackState.finished;
          notifyListeners();
        }
      });
    } catch (_) {
      if (token != _generation) return;
      _poller?.cancel();
      _state = SpeechPlaybackState.error;
      notifyListeners();
    }
  }

  void pause() {
    if (_state != SpeechPlaybackState.playing &&
        _state != SpeechPlaybackState.preparing) return;
    ++_generation;
    _poller?.cancel();
    _state = SpeechPlaybackState.paused;
    notifyListeners();
    unawaited(_stopAudio());
  }

  void resume() {
    if (_state != SpeechPlaybackState.paused &&
        _state != SpeechPlaybackState.stopped &&
        _state != SpeechPlaybackState.finished &&
        _state != SpeechPlaybackState.error) return;
    if (_state == SpeechPlaybackState.finished) _index = 0;
    _play();
  }

  void previous() {
    if (_phrases.isEmpty) return;
    if (_index > 0) _index--;
    _play();
  }

  void next() {
    if (_index + 1 >= _phrases.length) return;
    _index++;
    _play();
  }

  void stop() {
    if (!visible) return;
    ++_generation;
    _poller?.cancel();
    _index = 0;
    _state = SpeechPlaybackState.stopped;
    notifyListeners();
    unawaited(_stopAudio());
  }

  void close() {
    ++_generation;
    _poller?.cancel();
    _phrases = const [];
    _index = 0;
    _state = SpeechPlaybackState.idle;
    notifyListeners();
    unawaited(_stopAudio());
  }

  Future<void> _stopAudio() async {
    try {
      await _voice.stopSpeaking();
    } catch (_) {
      // Closing must still work when the native player is unavailable.
    }
  }

  @override
  void dispose() {
    ++_generation;
    _poller?.cancel();
    super.dispose();
  }
}
