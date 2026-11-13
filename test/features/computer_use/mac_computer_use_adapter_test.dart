import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/mac_computer_use_adapter.dart';

Uint8List fakeMacFrame() {
  final bytes = Uint8List(24);
  bytes.setRange(
    0, 8, <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  );
  ByteData.sublistView(bytes)
    ..setUint32(16, 1440)
    ..setUint32(20, 900);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aiorchestrator/mac_cu_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('Mac capture needs Screen Recording consent', () async {
    var captures = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'authorized': false};
      }
      if (call.method == 'captureScreenshot') {
        captures++;
        return fakeMacFrame();
      }
      return null;
    });
    final session = ComputerUseSession(
      adapter: MacComputerUseAdapter(
        channel: channel,
        supportedForTest: true,
      ),
    );
    session.beginSession(allowInteraction: false);
    final observation = await session.execute(
      <String, dynamic>{'action': 'observe'},
    );
    expect(observation.error, 'SCREEN_CONSENT_REQUIRED');
    expect(captures, 0);
  });

  test('Mac authorized native screen frame is accepted', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'authorized': true};
      }
      if (call.method == 'captureScreenshot') return fakeMacFrame();
      return null;
    });
    final session = ComputerUseSession(
      adapter: MacComputerUseAdapter(
        channel: channel,
        supportedForTest: true,
      ),
    );
    session.beginSession(allowInteraction: false);
    final observation = await session.execute(
      <String, dynamic>{'action': 'observe'},
    );
    expect(observation.success, isTrue);
    expect(observation.metadata['width'], 1440);
    expect(observation.metadata['height'], 900);
    final click = await session.execute(
      <String, dynamic>{'action': 'click', 'x': 100, 'y': 100},
    );
    expect(click.error, 'READ_ONLY_SESSION');
  });

  test('Mac adapter rejects interactive session grants', () {
    final session = ComputerUseSession(
      adapter: MacComputerUseAdapter(
        channel: channel,
        supportedForTest: true,
      ),
    );
    expect(
      () => session.beginSession(allowInteraction: true),
      throwsA(isA<ComputerUseException>().having(
        (error) => error.code, 'code', 'INTERACTION_UNSUPPORTED',
      )),
    );
  });

  test('Mac STOP invalidates pending native screenshot across regrant',
      () async {
    final pendingFrame = Completer<Uint8List>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'authorized': true};
      }
      if (call.method == 'captureScreenshot') return pendingFrame.future;
      return null;
    });
    final session = ComputerUseSession(
      adapter: MacComputerUseAdapter(
        channel: channel,
        supportedForTest: true,
      ),
    );
    session.beginSession(allowInteraction: false);
    final older = session.execute(
      <String, dynamic>{'action': 'observe'},
    );
    await Future<void>.delayed(Duration.zero);
    session.stop();
    session.beginSession(allowInteraction: false);
    pendingFrame.complete(fakeMacFrame());
    final result = await older;
    expect(result.success, isFalse);
    expect(result.error, 'SESSION_REVOKED');
    expect(session.isActive, isTrue);
  });

  test('Mac platform errors preserve permission-denied diagnostic', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object?>{'authorized': true};
      }
      if (call.method == 'captureScreenshot') {
        throw PlatformException(
          code: 'SCREEN_CONSENT_REQUIRED',
          message: 'Permission revoked by macOS',
        );
      }
      return null;
    });
    final session = ComputerUseSession(
      adapter: MacComputerUseAdapter(
        channel: channel,
        supportedForTest: true,
      ),
    );
    session.beginSession(allowInteraction: false);
    final result = await session.execute(
      <String, dynamic>{'action': 'observe'},
    );
    expect(result.error, 'SCREEN_CONSENT_REQUIRED');
  });
}
