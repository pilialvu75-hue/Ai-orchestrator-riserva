import 'package:ai_orchestrator/features/module_library/domain/delta_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('original Library module works offline and round-trips negatives', () {
    final samples = <int>[12, -4, -4, 9, 0];
    final original = List<int>.of(samples);
    expect(encodeDeltas(samples), <int>[12, -16, 0, 13, -9]);
    expect(decodeDeltas(encodeDeltas(samples)), original);
    expect(samples, original);
    expect(encodeDeltas(<int>[]), isEmpty);
    expect(decodeDeltas(<int>[]), isEmpty);
  });
}
