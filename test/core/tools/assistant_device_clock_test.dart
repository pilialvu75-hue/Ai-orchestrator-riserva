import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_device_clock.dart';

void main() {
  final clock = DateTime.utc(2026, 10, 20, 12, 42);
  test('uses supplied clock for observed Italian questions', () {
    expect(AssistantDeviceClock.answer('che ore sono?', clock), '12:42 (UTC+00:00) — orologio del dispositivo.');
    expect(AssistantDeviceClock.answer("la data e l'ora di oggi", clock), '20/10/2026, 12:42 (UTC+00:00) — orologio del dispositivo.');
    expect(AssistantDeviceClock.answer('data di oggi', clock), '20/10/2026 — orologio del dispositivo.');
    expect(AssistantDeviceClock.answer('che ore sono?', clock.add(const Duration(minutes: 1))), startsWith('12:43'));
  });
  test('does not intercept external clocks, explanations or mixed requests', () {
    for (final prompt in ['che ore sono a Tokyo?', 'che ore sono? e chi è il presidente?', 'traduci: che ore sono?', 'spiegami i fusi orari', 'che ore erano ieri?']) {
      expect(AssistantDeviceClock.answer(prompt, clock), isNull, reason: prompt);
    }
  });
}
