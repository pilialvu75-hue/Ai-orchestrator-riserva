import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_process_exit_diagnostics.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

void main() {
  const channel = MethodChannel('com.aiorchestrator/process_exit');

  testWidgets('records Android exit history arriving after startup timeout',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final response = Completer<List<Map<String, Object>>>();
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) => response.future);
    RuntimeEventLog.instance.clear();
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    var returned = false;
    final recording = recordAndroidProcessExitHistory().then((_) {
      returned = true;
    });
    await tester.pump(const Duration(seconds: 3));
    await recording;
    expect(returned, isTrue);
    expect(RuntimeEventLog.instance.entries
        .where((e) => e.tag == 'ANDROID_PROCESS_EXIT_HISTORY'), isEmpty);

    response.complete([
      {'timestamp_ms': 1234, 'reason_code': 5, 'status': 6},
    ]);
    await tester.pump();
    final records = RuntimeEventLog.instance.entries
        .where((e) => e.tag == 'ANDROID_PROCESS_EXIT_HISTORY').toList();
    expect(records, hasLength(1));
    expect(records.single.message, contains('"timestamp_ms":1234'));
    await tester.pump();
  });
}
