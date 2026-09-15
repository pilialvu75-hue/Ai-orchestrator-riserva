import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_foreground_execution_lease.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android Cantiere lease uses the shared foreground bridge', () async {
    const channel = MethodChannel('test/workshop_foreground_execution');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object>{'ok': true};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final service = WorkshopForegroundExecutionLeaseService(
      channel: channel,
      platformOverride: TargetPlatform.android,
    );

    final lease = await service.acquire(operationId: 'task-42:analysis');
    await lease.release();
    await lease.release();

    expect(calls, hasLength(2));
    expect(calls.first.method, 'acquire');
    final acquireArgs = calls.first.arguments as Map<Object?, Object?>;
    expect(acquireArgs['kind'], 'workshop');
    expect(acquireArgs['sessionId'], 'task-42:analysis');
    expect(acquireArgs['provider'], 'workshop');
    expect(acquireArgs['leaseId'], startsWith('workshop-task-42:analysis-'));

    expect(calls.last.method, 'release');
    final releaseArgs = calls.last.arguments as Map<Object?, Object?>;
    expect(releaseArgs['leaseId'], acquireArgs['leaseId']);
  });

  test('non-Android Cantiere lease stays a no-op', () async {
    const channel = MethodChannel('test/workshop_foreground_execution_noop');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls += 1;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final service = WorkshopForegroundExecutionLeaseService(
      channel: channel,
      platformOverride: TargetPlatform.windows,
    );

    final lease = await service.acquire(operationId: 'task-42:planning');
    await lease.release();

    expect(calls, 0);
  });
}
