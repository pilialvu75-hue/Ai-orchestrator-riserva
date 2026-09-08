import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const bridgePath = 'native/android/llama_bridge.cpp';

  String loadBridge() {
    final file = File(bridgePath);
    expect(file.existsSync(), isTrue, reason: '$bridgePath must exist');
    return file.readAsStringSync();
  }

  bool isInsideDebugGuard(String source, String marker) {
    final markerIndex = source.indexOf(marker);
    expect(markerIndex, greaterThanOrEqualTo(0), reason: 'Missing $marker');

    final prefix = source.substring(0, markerIndex);
    final lastDebugGuard = prefix.lastIndexOf('#ifndef NDEBUG');
    final lastGuardEnd = prefix.lastIndexOf('#endif');
    return lastDebugGuard > lastGuardEnd;
  }

  group('native release logging contract', () {
    test('raw prompt dump is debug-only', () {
      final source = loadBridge();

      expect(
        isInsideDebugGuard(
          source,
          '[PROMPT_DEBUG] --- INIZIO PROMPT REALE ---',
        ),
        isTrue,
      );
    });

    test('per-prompt-token forensics is debug-only', () {
      final source = loadBridge();

      expect(
        isInsideDebugGuard(source, '[FORENSIC_PROMPT_TOKEN]'),
        isTrue,
      );
    });

    test('control-token piece diagnostics is debug-only', () {
      final source = loadBridge();

      expect(
        isInsideDebugGuard(source, '[FORENSIC_CONTROL_TOKEN]'),
        isTrue,
      );
    });

    test('release keeps compact tokenization telemetry', () {
      final source = loadBridge();

      expect(source, contains('[TOKENIZE] session='));
      expect(
        isInsideDebugGuard(source, '[TOKENIZE] session='),
        isFalse,
      );
    });
  });
}
