import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_next_turn_gate.dart';

void main() {
  test('no second turn starts until the user requests it', () async {
    final gate = LiveNextTurnGate();
    var finished = false;
    final waiting = gate.waitForUser().then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(gate.isWaiting, isTrue);
    expect(finished, isFalse);
    expect(gate.requestNextTurn(), isTrue);
    await waiting;
    expect(finished, isTrue);
    expect(gate.isWaiting, isFalse);
    expect(gate.requestNextTurn(), isFalse);
  });

  test('duplicate requests cannot start multiple turns', () async {
    final gate = LiveNextTurnGate();
    final waiting = gate.waitForUser();
    expect(gate.requestNextTurn(), isTrue);
    expect(gate.requestNextTurn(), isFalse);
    await waiting;
  });

  test('closing releases wait and refuses new turns', () async {
    final gate = LiveNextTurnGate();
    final waiting = gate.waitForUser();
    gate.close();
    await waiting;
    expect(gate.requestNextTurn(), isFalse);
    await gate.waitForUser();
    expect(gate.isWaiting, isFalse);
  });

  test('concurrent waiters share one gate', () async {
    final gate = LiveNextTurnGate();
    final a = gate.waitForUser();
    final b = gate.waitForUser();
    expect(identical(a, b), isTrue);
    expect(gate.requestNextTurn(), isTrue);
    await Future.wait(<Future<void>>[a, b]);
  });
}
