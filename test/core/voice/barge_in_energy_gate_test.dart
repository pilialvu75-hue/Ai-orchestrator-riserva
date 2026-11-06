import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/barge_in_energy_gate.dart';

void main() {
  final loud20ms = Float32List.fromList(List<double>.filled(320, 0.12));
  final silent20ms = Float32List(320);

  test('never interrupts without verified echo suppression', () {
    final gate = BargeInEnergyGate();
    for (var i = 0; i < 12; i++) {
      expect(gate.process(loud20ms,
          assistantSpeaking: true, echoSuppressed: false), isFalse);
    }
  });

  test('requires sustained energy and only triggers once per burst', () {
    final gate = BargeInEnergyGate();
    for (var i = 0; i < 5; i++) {
      expect(gate.process(loud20ms,
          assistantSpeaking: true, echoSuppressed: true), isFalse);
    }
    expect(gate.process(loud20ms,
        assistantSpeaking: true, echoSuppressed: true), isTrue);
    expect(gate.process(loud20ms,
        assistantSpeaking: true, echoSuppressed: true), isFalse);
    expect(gate.process(silent20ms,
        assistantSpeaking: true, echoSuppressed: true), isFalse);
    for (var i = 0; i < 5; i++) {
      expect(gate.process(loud20ms,
          assistantSpeaking: true, echoSuppressed: true), isFalse);
    }
    expect(gate.process(loud20ms,
        assistantSpeaking: true, echoSuppressed: true), isTrue);
  });

  test('cannot trigger while assistant is not speaking', () {
    final gate = BargeInEnergyGate();
    for (var i = 0; i < 10; i++) {
      expect(gate.process(loud20ms,
          assistantSpeaking: false, echoSuppressed: true), isFalse);
    }
  });

  test('invalid PCM cannot trigger interruption', () {
    final gate = BargeInEnergyGate();
    final corrupt = Float32List.fromList([double.nan, 0.3]);
    expect(gate.process(corrupt,
        assistantSpeaking: true, echoSuppressed: true), isFalse);
  });
}
