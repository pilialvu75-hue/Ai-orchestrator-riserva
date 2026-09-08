import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const bridgePath = 'native/android/llama_bridge.cpp';

  String loadBridge() {
    final file = File(bridgePath);
    expect(file.existsSync(), isTrue, reason: '$bridgePath must exist');
    return file.readAsStringSync();
  }

  bool allOccurrencesMatchDebugGuard(
    String source,
    String marker, {
    required bool expectedInsideDebugGuard,
  }) {
    final preprocessorStack = <bool>[];
    var occurrences = 0;

    for (final line in source.split('\n')) {
      final trimmed = line.trimLeft();

      if (trimmed.startsWith('#ifndef NDEBUG')) {
        preprocessorStack.add(true);
        continue;
      }
      if (trimmed.startsWith('#if ') ||
          trimmed.startsWith('#ifdef ') ||
          trimmed.startsWith('#ifndef ')) {
        preprocessorStack.add(false);
        continue;
      }
      if (trimmed.startsWith('#endif')) {
        if (preprocessorStack.isNotEmpty) {
          preprocessorStack.removeLast();
        }
        continue;
      }

      var searchFrom = 0;
      while (true) {
        final markerIndex = line.indexOf(marker, searchFrom);
        if (markerIndex < 0) {
          break;
        }
        occurrences++;
        final insideDebugGuard = preprocessorStack.contains(true);
        if (insideDebugGuard != expectedInsideDebugGuard) {
          return false;
        }
        searchFrom = markerIndex + marker.length;
      }
    }

    expect(occurrences, greaterThan(0), reason: 'Missing $marker');
    return true;
  }

  group('native release logging contract', () {
    test('every raw prompt dump marker is debug-only', () {
      final source = loadBridge();

      expect(
        allOccurrencesMatchDebugGuard(
          source,
          '[PROMPT_DEBUG]',
          expectedInsideDebugGuard: true,
        ),
        isTrue,
      );
    });

    test('every per-prompt-token forensic marker is debug-only', () {
      final source = loadBridge();

      expect(
        allOccurrencesMatchDebugGuard(
          source,
          '[FORENSIC_PROMPT_TOKEN]',
          expectedInsideDebugGuard: true,
        ),
        isTrue,
      );
    });

    test('every control-token diagnostic marker is debug-only', () {
      final source = loadBridge();

      expect(
        allOccurrencesMatchDebugGuard(
          source,
          '[FORENSIC_CONTROL_TOKEN]',
          expectedInsideDebugGuard: true,
        ),
        isTrue,
      );
    });

    test('every compact tokenization marker remains release-visible', () {
      final source = loadBridge();

      expect(
        allOccurrencesMatchDebugGuard(
          source,
          '[TOKENIZE] session=',
          expectedInsideDebugGuard: false,
        ),
        isTrue,
      );
    });
  });
}
