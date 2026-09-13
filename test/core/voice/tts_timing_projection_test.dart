import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';

void main() {
  test('public timings preserve only exact numeric producer fields', () {
    final row = jsonDecode(publicLogProjection(
      '[2026-09-13T16:00:00.000] [VOICE_ENGINE] [TTS_TIMING] reused=true load_ms=0 synthesis_ms=1500')!);
    expect(row['load_ms'], 0);
    expect(row['synthesis_ms'], 1500);
    expect(row['reused'], true);
    final invalid = publicLogProjection(
      '[2026-09-13T16:00:00.000] [TTS_TIMING] reused=true load_ms=0 synthesis_ms=1500 secret=private')!;
    expect(invalid, isNot(contains('private')));
    expect(jsonDecode(invalid)['load_ms'], isNull);
  });
}
