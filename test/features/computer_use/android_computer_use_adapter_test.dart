import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/android_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

Uint8List _frame() {
  final bytes = Uint8List(24);
  bytes.setRange(
    0, 8, <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  );
  ByteData.sublistView(bytes)
    ..setUint32(16, 1280)
    ..setUint32(20, 720);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aiorchestrator/cu_android_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('screen consent is mandatory before observation', () async {
    var captureCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'active': false, 'supported': true};
      }
      if (call.method == 'captureScreenshot') {
        captureCalls++;
        return _frame();
      }
      return null;
    });
    final adapter = AndroidComputerUseAdapter(
      channel: channel,
      supportedForTest: true,
    );
    final session = ComputerUseSession(adapter: adapter);
    session.beginSession(allowInteraction: false);
    final result = await session.execute(<String, dynamic>{
      'action': 'observe',
    });
    expect(result.success, isFalse);
    expect(result.error, 'SCREEN_CONSENT_REQUIRED');
    expect(captureCalls, 0);
  });

  test('authorized Android projection is read-only and returns PNG', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'active': true, 'supported': true};
      }
      if (call.method == 'captureScreenshot') return _frame();
      return null;
    });
    final adapter = AndroidComputerUseAdapter(
      channel: channel,
      supportedForTest: true,
    );
    final session = ComputerUseSession(adapter: adapter);
    session.beginSession(allowInteraction: false);
    final observed = await session.execute(<String, dynamic>{
      'action': 'observe',
    });
    expect(observed.success, isTrue);
    expect(observed.metadata['width'], 1280);
    expect(observed.metadata['height'], 720);
    final denied = await session.execute(<String, dynamic>{
      'action': 'click', 'x': 12, 'y': 12,
    });
    expect(denied.error, 'READ_ONLY_SESSION');
  });

  test('Android cannot grant interactive access', () {
    final adapter = AndroidComputerUseAdapter(
      channel: channel,
      supportedForTest: true,
    );
    final session = ComputerUseSession(adapter: adapter);
    expect(
      () => session.beginSession(allowInteraction: true),
      throwsA(
        isA<ComputerUseException>().having(
          (error) => error.code,
          'code',
          'INTERACTION_UNSUPPORTED',
        ),
      ),
    );
    expect(session.canInteract, isFalse);
  });

  test('STOP invalidates a screenshot still awaiting the channel', () async {
    final screenshot = Completer<Uint8List>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'active': true};
      }
      if (call.method == 'captureScreenshot') return screenshot.future;
      return null;
    });
    final adapter = AndroidComputerUseAdapter(
      channel: channel,
      supportedForTest: true,
    );
    final session = ComputerUseSession(adapter: adapter);
    session.beginSession(allowInteraction: false);
    final pending = session.execute(<String, dynamic>{
      'action': 'observe',
    });
    await Future<void>.delayed(Duration.zero);
    session.stop();
    session.beginSession(allowInteraction: false);
    screenshot.complete(_frame());
    final old = await pending;
    expect(old.success, isFalse);
    expect(old.error, 'SESSION_REVOKED');
    expect(session.isActive, isTrue);
  });
}
