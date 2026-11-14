import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/live_response_text_assembler.dart';

void main() {
  test('intermediate tokens + complete final emit each character once', () {
    final a = LiveResponseTextAssembler();
    expect(a.add(text: 'Buona', isFinal: false), 'Buona');
    expect(a.add(text: 'sera! ', isFinal: false), 'sera! ');
    expect(a.add(text: 'Come stai?', isFinal: false), 'Come stai?');
    expect(a.add(
      text: 'Buonasera! Come stai?', isFinal: true), isEmpty);
    expect(a.text, 'Buonasera! Come stai?');
    expect(a.finalMismatch, isFalse);
  });

  test('one final-only response is kept, not lost', () {
    final a = LiveResponseTextAssembler();
    expect(a.add(text: 'Solo risposta.', isFinal: true), 'Solo risposta.');
    expect(a.text, 'Solo risposta.');
  });

  test('final with an additional suffix forwards the suffix once', () {
    final a = LiveResponseTextAssembler();
    a.add(text: 'Una frase.', isFinal: false);
    expect(a.add(text: 'Una frase. Fine.', isFinal: true), ' Fine.');
    expect(a.text, 'Una frase. Fine.');
  });

  test('different final text never repeats already spoken tokens', () {
    final a = LiveResponseTextAssembler();
    a.add(text: 'Risposta già generata.', isFinal: false);
    expect(a.add(text: 'Divergente.', isFinal: true), isEmpty);
    expect(a.text, 'Risposta già generata.');
    expect(a.finalMismatch, isTrue);
  });

  test('Chinese or other unicode chunks are not duplicated', () {
    final a = LiveResponseTextAssembler();
    a.add(text: '洋葱', isFinal: false);
    expect(a.add(text: '洋葱', isFinal: true), isEmpty);
    expect(a.text, '洋葱');
  });

  test('empty terminal chunks do not remove already streamed content', () {
    final a = LiveResponseTextAssembler();
    a.add(text: 'Ciao', isFinal: false);
    expect(a.add(text: '', isFinal: true), isEmpty);
    expect(a.text, 'Ciao');
  });
}
