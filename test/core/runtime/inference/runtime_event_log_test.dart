import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    RuntimeEventLog.instance.resetForTest();
  });

  test('restores persisted runtime diagnostics entries on initialization', () async {
    SharedPreferences.setMockInitialValues({
      RuntimeEventLog.persistenceStorageKey: <String>[
        jsonEncode({
          'timestamp': '2026-05-24T00:00:00.000Z',
          'message': '[FORENSIC_FIRST_TOKEN] sessionId=test nativeSessionId=7 chars=12',
        }),
      ],
    });
    final preferences = await SharedPreferences.getInstance();

    await RuntimeEventLog.instance.initializePersistence(
      preferences: preferences,
    );

    final entry = RuntimeEventLog.instance.entries.single;
    expect(entry.tag, 'FORENSIC_FIRST_TOKEN');
    expect(
      entry.message,
      '[FORENSIC_FIRST_TOKEN] sessionId=test nativeSessionId=7 chars=12',
    );
  });

  test('persists emitted entries and clears persisted diagnostics buffer', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final log = RuntimeEventLog.instance;

    await log.initializePersistence(preferences: preferences);
    log.emit('[FORENSIC_DIAGNOSTICS_PIPELINE_VERIFIED] startup');
    await Future<void>.delayed(Duration.zero);

    final storedAfterEmit =
        preferences.getStringList(RuntimeEventLog.persistenceStorageKey);
    expect(storedAfterEmit, isNotNull);
    expect(storedAfterEmit, hasLength(1));
    expect(
      jsonDecode(storedAfterEmit!.single)['message'],
      '[FORENSIC_DIAGNOSTICS_PIPELINE_VERIFIED] startup',
    );

    log.clear();
    await Future<void>.delayed(Duration.zero);

    expect(
      preferences.getStringList(RuntimeEventLog.persistenceStorageKey),
      isNull,
    );
  });
}
