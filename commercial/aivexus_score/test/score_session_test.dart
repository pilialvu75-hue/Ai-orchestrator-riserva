import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aivexus_score/score_session.dart';

void main() {
  test('both players score independently and scores cannot go below zero', () {
    final session = ScoreSession();
    expect(session.adjust(isHome: true, by: -1), isFalse);
    expect(session.adjust(isHome: true, by: 1), isTrue);
    expect(session.adjust(isHome: false, by: 1), isTrue);
    expect(session.home, 1);
    expect(session.away, 1);
    expect(session.undo(), isTrue);
    expect(session.home, 1);
    expect(session.away, 0);
  });

  test('reset requires an existing score and can be undone', () {
    final session = ScoreSession();
    expect(session.reset(), isFalse);
    session.adjust(isHome: true, by: 1);
    session.adjust(isHome: true, by: 1);
    expect(session.reset(), isTrue);
    expect(session.home, 0);
    expect(session.undo(), isTrue);
    expect(session.home, 2);
  });

  test('session JSON retains names, scores and undo history', () {
    final session = ScoreSession();
    session.rename(isHome: true, value: '  Alice  ');
    session.rename(isHome: false, value: 'Bob');
    session.adjust(isHome: true, by: 1);
    session.adjust(isHome: false, by: 1);
    final restored = ScoreSession.fromEncoded(jsonEncode(session.toJson()));
    expect(restored.homeName, 'Alice');
    expect(restored.awayName, 'Bob');
    expect(restored.home, 1);
    expect(restored.away, 1);
    expect(restored.undo(), isTrue);
    expect(restored.home, 1);
    expect(restored.away, 0);
  });

  test('bad saved state is ignored without crashing', () {
    expect(ScoreSession.fromEncoded('not json').home, 0);
    expect(ScoreSession.fromEncoded('[]').home, 0);
    expect(ScoreSession.fromEncoded('{"version":2}').home, 0);
    expect(
      ScoreSession.fromEncoded('{"version":1,"home":-4,"away":9999999}').away,
      0,
    );
  });

  test('history is bounded and score has a safe maximum', () {
    final session = ScoreSession();
    for (var i = 0; i < 50; i++) {
      session.adjust(isHome: true, by: 1);
    }
    var undos = 0;
    while (session.undo()) {
      undos++;
    }
    expect(undos, ScoreSession.maxHistory);
    final cap = ScoreSession(home: ScoreSession.maxScore);
    expect(cap.adjust(isHome: true, by: 1), isFalse);
    expect(cap.home, ScoreSession.maxScore);
  });
  test('100 sequential score actions and 20 reset/undo cycles stay consistent', () {
    final session = ScoreSession();
    for (var i = 0; i < 100; i++) {
      expect(session.adjust(isHome: i.isEven, by: 1), isTrue);
    }
    expect((session.home, session.away), (50, 50));

    for (var i = 0; i < 20; i++) {
      expect(session.reset(), isTrue);
      expect((session.home, session.away), (0, 0));
      expect(session.undo(), isTrue);
      expect((session.home, session.away), (50, 50));
    }

    final resumed = ScoreSession.fromEncoded(jsonEncode(session.toJson()));
    expect((resumed.home, resumed.away), (50, 50));
  });

}
