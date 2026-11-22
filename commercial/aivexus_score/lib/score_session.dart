import 'dart:convert';

/// Local-only scorekeeping state. No network, account or analytics.
class ScoreSession {
  ScoreSession({
    this.home = 0,
    this.away = 0,
    this.homeName = 'A',
    this.awayName = 'B',
  });

  static const int maxScore = 999999;
  static const int maxHistory = 30;

  int home;
  int away;
  String homeName;
  String awayName;
  final List<(int, int)> _history = <(int, int)>[];

  bool get canUndo => _history.isNotEmpty;

  bool adjust({required bool isHome, required int by}) {
    if (by != -1 && by != 1) {
      throw ArgumentError.value(by, 'by', 'Only +1 or -1 is allowed');
    }
    final value = isHome ? home : away;
    final next = value + by;
    if (next < 0 || next > maxScore) return false;
    _remember();
    if (isHome) {
      home = next;
    } else {
      away = next;
    }
    return true;
  }

  bool reset() {
    if (home == 0 && away == 0) return false;
    _remember();
    home = 0;
    away = 0;
    return true;
  }

  bool undo() {
    if (_history.isEmpty) return false;
    final previous = _history.removeLast();
    home = previous.$1;
    away = previous.$2;
    return true;
  }

  void rename({required bool isHome, required String value}) {
    final name = value.trim();
    if (name.isEmpty || name.length > 24) return;
    if (isHome) {
      homeName = name;
    } else {
      awayName = name;
    }
  }

  void _remember() {
    if (_history.length == maxHistory) _history.removeAt(0);
    _history.add((home, away));
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'home': home,
    'away': away,
    'homeName': homeName,
    'awayName': awayName,
    'history': _history
        .map((entry) => <int>[entry.$1, entry.$2])
        .toList(growable: false),
  };

  static ScoreSession fromEncoded(String? text) {
    if (text == null || text.isEmpty) return ScoreSession();
    try {
      final data = jsonDecode(text);
      if (data is! Map<String, dynamic> || data['version'] != 1) {
        return ScoreSession();
      }
      int score(Object? number) =>
          number is int && number >= 0 && number <= maxScore ? number : 0;
      String name(Object? name, String fallback) =>
          name is String && name.trim().isNotEmpty && name.length <= 24
              ? name.trim()
              : fallback;
      final result = ScoreSession(
        home: score(data['home']),
        away: score(data['away']),
        homeName: name(data['homeName'], 'A'),
        awayName: name(data['awayName'], 'B'),
      );
      final history = data['history'];
      if (history is List) {
        for (final entry in history.take(maxHistory)) {
          if (entry is List &&
              entry.length == 2 &&
              entry[0] is int &&
              entry[1] is int &&
              entry[0] >= 0 &&
              entry[1] >= 0 &&
              entry[0] <= maxScore &&
              entry[1] <= maxScore) {
            result._history.add((entry[0] as int, entry[1] as int));
          }
        }
      }
      return result;
    } on FormatException {
      return ScoreSession();
    } on TypeError {
      return ScoreSession();
    }
  }
}
