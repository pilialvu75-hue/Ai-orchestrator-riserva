import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/completion_output.dart';

void main() {
  test('removes terminal transport marker at every chunk split and newline style', () async {
    for (final suffix in [' [end of text]\n\n', '[end of text]\r\n\r\n', ' [end of text]   \n', ' [end of text]\n [end of text]\n']) {
      final value = 'Città: perché è così.$suffix';
      for (var split = 0; split <= value.length; split++) {
        expect(await CompletionOutput.visible(Stream.fromIterable([value.substring(0, split), value.substring(split)])).join(), 'Città: perché è così.', reason: 'suffix=$suffix split=$split');
      }
      expect(await CompletionOutput.visible(Stream.fromIterable(value.split(''))).join(), 'Città: perché è così.');
    }
  });
  test('preserves ordinary text, literal inner markers and incomplete markers', () async {
    for (final value in ['Ciao', 'Testo con spazi finali  ', 'Il simbolo [end of text] è un marcatore.', 'Parte [end of tex', 'Il presidente è un dato da verificare.']) {
      expect(await CompletionOutput.visible(Stream.fromIterable(value.split(''))).join(), value);
    }
  });
  test('short first content arrives before process completion', () async {
    final controller = StreamController<String>();
    final seen = <String>[];
    final done = CompletionOutput.visible(controller.stream).listen(seen.add).asFuture<void>();
    controller.add('Ciao');
    await Future<void>.delayed(Duration.zero);
    expect(seen.join(), 'Ciao');
    controller.add(' [end of text]\n\n');
    await controller.close();
    await done;
    expect(seen.join(), 'Ciao');
  });
}
