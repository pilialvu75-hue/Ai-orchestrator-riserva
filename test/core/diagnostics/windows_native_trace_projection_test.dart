import 'dart:convert';

import 'package:ai_orchestrator/core/diagnostics/windows_native_trace_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final capturedAt = DateTime.utc(2026, 9, 30, 14, 0);

  test('exports stages and fatal module without absolute paths or addresses', () {
    final line = windowsNativeTracePublicProjection(
      r'''
00 fatal capture installed (diagnostics v2)
01 wWinMain entered
14 window.Create returned true
FATAL native exception observed
fatal_exception_code=0xC0000005
fatal_exception_address=0x0000000012345678
fatal_module=C:\Windows\System32\ucrtbase.dll
fatal_stack_00=0x0000000087654321
fatal_stack_module=C:\Program Files\AI Orchestrator\ai_orchestrator.exe
''',
      source: 'previous',
      capturedAt: capturedAt,
    );

    final data = jsonDecode(line!) as Map<String, dynamic>;
    expect(data['event'], 'WINDOWS_NATIVE_TRACE');
    expect(data['source'], 'previous');
    expect(data['last_stage'], '14');
    expect(data['fatal'], isTrue);
    expect(data['exception_code'], '0XC0000005');
    expect(data['fault_module'], 'ucrtbase.dll');
    expect(data['stack_modules'], contains('ai_orchestrator.exe'));
    expect(line, isNot(contains(r'C:\Windows')));
    expect(line, isNot(contains('12345678')));
    expect(line, isNot(contains('87654321')));
  });

  test('exports clean startup/shutdown state', () {
    final line = windowsNativeTracePublicProjection(
      '01 wWinMain entered\n17 clean shutdown\n',
      source: 'current',
      capturedAt: capturedAt,
    );

    final data = jsonDecode(line!) as Map<String, dynamic>;
    expect(data['last_stage'], '17');
    expect(data['fatal'], isFalse);
    expect(data['clean_shutdown'], isTrue);
  });

  test('rejects unknown source and arbitrary text', () {
    expect(
      windowsNativeTracePublicProjection(
        'private user text',
        source: 'current',
        capturedAt: capturedAt,
      ),
      isNull,
    );
    expect(
      windowsNativeTracePublicProjection(
        '01 wWinMain entered',
        source: 'private',
        capturedAt: capturedAt,
      ),
      isNull,
    );
  });
}
