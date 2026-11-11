import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

class FakeDesktop implements ComputerUseAdapter {
  FakeDesktop({this.isSupported = true});

  @override
  final bool isSupported;

  int cancellations = 0;

  @override
  void cancel() => cancellations++;

  int captures = 0;
  int selections = 0;
  int launches = 0;
  String? launchedApp;
  Completer<Uint8List>? blockedCapture;

  @override
  Future<void> selectForegroundWindow() async => selections++;

  @override
  Future<void> openApplication(String application) async {
    launches++;
    launchedApp = application;
  }

  int clicks = 0;
  int typing = 0;
  int keys = 0;
  String? lastText;

  @override
  Future<Uint8List> capturePng() async {
    captures++;
    if (blockedCapture case final pending?) return pending.future;
    return validFrame();
  }

  static Uint8List validFrame() {
    final image = Uint8List(24);
    image.setRange(
      0,
      8,
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    );
    final data = ByteData.sublistView(image);
    data.setUint32(16, 1920);
    data.setUint32(20, 1080);
    return image;
  }

  @override
  Future<void> click(int x, int y) async => clicks++;

  @override
  Future<void> typeText(String text) async {
    typing++;
    lastText = text;
  }

  @override
  Future<void> pressKey(String key) async => keys++;
}

void main() {
  group('ComputerUseSession', () {
    test('no UI grant: tool calls cannot start or observe', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      final result = await session.execute(<String, dynamic>{
        'action': 'observe',
        'authorized': true,
      });
      expect(result.success, isFalse);
      expect(result.error, 'SESSION_INACTIVE');
      expect(adapter.captures, 0);
      final escalate = await session.execute(<String, dynamic>{
        'action': 'begin',
        'allowInteraction': true,
      });
      expect(escalate.success, isFalse);
      expect(session.isActive, isFalse);
    });

    test('read-only observation never permits an input action', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: false);
      final observation = await session.execute(<String, dynamic>{
        'action': 'observe',
      });
      expect(observation.success, isTrue);
      expect(observation.metadata['width'], 1920);
      expect(adapter.captures, 1);
      final click = await session.execute(<String, dynamic>{
        'action': 'click',
        'x': 200,
        'y': 200,
      });
      expect(click.error, 'READ_ONLY_SESSION');
      expect(adapter.clicks, 0);
    });

    test('interactive calls require prior observation and valid bounds',
        () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final premature = await session.execute(<String, dynamic>{
        'action': 'click',
        'x': 100,
        'y': 100,
      });
      expect(premature.error, 'INVALID_COORDINATES');
      await session.execute(<String, dynamic>{'action': 'observe'});
      final outside = await session.execute(<String, dynamic>{
        'action': 'click',
        'x': 1920,
        'y': 0,
      });
      expect(outside.success, isFalse);
      final valid = await session.execute(<String, dynamic>{
        'action': 'click',
        'x': 1919,
        'y': 1079,
      });
      expect(valid.success, isTrue);
      expect(adapter.clicks, 1);
    });

    test('text is bounded and never echoed in tool output', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final longText = await session.execute(<String, dynamic>{
        'action': 'type_text',
        'text': 'a' * 513,
      });
      expect(longText.error, 'INVALID_TEXT');
      final inserted = await session.execute(<String, dynamic>{
        'action': 'type_text',
        'text': 'segreto-sintetico',
      });
      expect(inserted.success, isTrue);
      expect(inserted.output, isNot(contains('segreto-sintetico')));
      expect(adapter.lastText, 'segreto-sintetico');
      expect(adapter.typing, 1);
    });

    test('application launches require authorization and explicit allowlist',
        () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: false);
      final readOnly = await session.execute(<String, dynamic>{
        'action': 'open_app',
        'app': 'notepad',
      });
      expect(readOnly.error, 'READ_ONLY_SESSION');
      session.beginSession(allowInteraction: true);
      final denied = await session.execute(<String, dynamic>{
        'action': 'open_app',
        'app': 'powershell',
      });
      expect(denied.error, 'APPLICATION_NOT_ALLOWED');
      expect(adapter.launches, 0);
      final launched = await session.execute(<String, dynamic>{
        'action': 'open_app',
        'app': 'notepad',
      });
      expect(launched.success, isTrue);
      expect(adapter.launches, 1);
      expect(adapter.launchedApp, 'notepad');
    });

    test('target window binding needs interactive session', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: false);
      final refused = await session.execute(<String, dynamic>{
        'action': 'select_window',
      });
      expect(refused.error, 'READ_ONLY_SESSION');
      expect(adapter.selections, 0);
      session.beginSession(allowInteraction: true);
      final selected = await session.execute(<String, dynamic>{
        'action': 'select_window',
      });
      expect(selected.success, isTrue);
      expect(adapter.selections, 1);
    });

    test('STOP invalidates an in-flight screenshot', () async {
      final adapter = FakeDesktop();
      adapter.blockedCapture = Completer<Uint8List>();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final ongoing = session.execute(<String, dynamic>{'action': 'observe'});
      final busy = await session.execute(<String, dynamic>{'action': 'observe'});
      expect(busy.error, 'OPERATION_BUSY');
      final stopped = await session.execute(<String, dynamic>{'action': 'stop'});
      expect(stopped.success, isTrue);
      adapter.blockedCapture!.complete(FakeDesktop.validFrame());
      final finished = await ongoing;
      expect(finished.error, 'SESSION_INACTIVE');
      expect(session.isActive, isFalse);
    });

    test('only navigation keys are supported', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final blocked = await session.execute(<String, dynamic>{
        'action': 'press_key',
        'key': 'ctrl+alt+delete',
      });
      expect(blocked.error, 'INVALID_KEY');
      final allowed = await session.execute(<String, dynamic>{
        'action': 'press_key',
        'key': 'tab',
      });
      expect(allowed.success, isTrue);
      expect(adapter.keys, 1);
    });

    test('stop revokes permission, expiry is not renewable by tools',
        () async {
      var now = DateTime.utc(2026, 11, 11);
      final adapter = FakeDesktop();
      final session = ComputerUseSession(
        adapter: adapter,
        clock: () => now,
        sessionLifetime: const Duration(minutes: 10),
      );
      session.beginSession(allowInteraction: true);
      expect(session.isActive, isTrue);
      now = now.add(const Duration(minutes: 11));
      expect(session.isActive, isFalse);
      final expired = await session.execute(<String, dynamic>{
        'action': 'observe',
      });
      expect(expired.error, 'SESSION_INACTIVE');
      expect(adapter.captures, 0);
      session.beginSession(allowInteraction: true);
      final stopped = await session.execute(<String, dynamic>{
        'action': 'stop',
      });
      expect(stopped.success, isTrue);
      expect(session.isActive, isFalse);
      expect(adapter.cancellations, greaterThanOrEqualTo(2));
    });

    test('unsupported adapters never open a session', () {
      final session = ComputerUseSession(
        adapter: FakeDesktop(isSupported: false),
      );
      expect(
        () => session.beginSession(allowInteraction: true),
        throwsA(isA<ComputerUseException>()),
      );
    });
  });
}
