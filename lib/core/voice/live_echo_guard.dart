/// Conservative protection against the desktop microphone capturing the
/// assistant's recent synthetic speech. No transcript is logged or persisted.
class LiveEchoGuard {
  LiveEchoGuard({this.maxAge = const Duration(seconds: 20)});

  final Duration maxAge;
  final List<String> _phrases = <String>[];
  DateTime? _playbackEndedAt;

  static String normalize(String text) => text.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9à-ÿ]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  void rememberSpoken(String phrase) {
    final normalized = normalize(phrase);
    if (normalized.isEmpty) return;
    _phrases.add(normalized);
    if (_phrases.length > 16) _phrases.removeAt(0);
  }

  void playbackEnded({DateTime? at}) {
    if (_phrases.isNotEmpty) _playbackEndedAt = at ?? DateTime.now();
  }

  bool isLikelyPlaybackEcho(String recognized, {DateTime? now}) {
    final ended = _playbackEndedAt;
    if (ended == null || _phrases.isEmpty) return false;
    final elapsed = (now ?? DateTime.now()).difference(ended);
    if (elapsed.isNegative || elapsed > maxAge) return false;
    final candidate = normalize(recognized);
    // Do not block short normal replies, acknowledgments, or repeat requests.
    if (candidate.length < 16 || candidate.split(' ').length < 3) {
      return false;
    }
    final answer = _phrases.join(' ');
    return answer.contains(candidate);
  }

  void clear() {
    _phrases.clear();
    _playbackEndedAt = null;
  }
}
