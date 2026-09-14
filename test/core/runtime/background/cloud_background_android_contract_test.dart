import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android manifest declares Cloud data-sync foreground service', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    expect(manifest.existsSync(), isTrue);
    final source = manifest.readAsStringSync();

    expect(source, contains('android.permission.FOREGROUND_SERVICE'));
    expect(source, contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'));
    expect(source, contains('android:name=".CloudBackgroundExecutionService"'));
    expect(source, contains('android:exported="false"'));
    expect(source, contains('android:foregroundServiceType="dataSync"'));
  });

  test('root Android bootstrap registers Cloud background channel', () {
    final bootstrap = File(
      'android/app/src/main/kotlin/com/aiorchestrator/BackgroundDownloads.kt',
    );
    expect(bootstrap.existsSync(), isTrue);
    final source = bootstrap.readAsStringSync();

    expect(
      source,
      contains('CloudBackgroundExecution.register(app, engine)'),
    );
  });

  test('Cloud foreground service never accepts prompt or credential payloads', () {
    final service = File(
      'android/app/src/main/kotlin/com/aiorchestrator/CloudBackgroundExecution.kt',
    );
    expect(service.existsSync(), isTrue);
    final source = service.readAsStringSync();

    expect(source, contains('ai_orchestrator/cloud_background'));
    expect(source, contains('leaseId'));
    expect(source, isNot(contains('apiKey')));
    expect(source, isNot(contains('userPrompt')));
  });
}
