import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_smoke_scenario.dart';

class FakeDesktop implements ComputerUseAdapter, ComputerUseInteractionCapability {
  FakeDesktop({this.isSupported = true});

  @override
  final bool isSupported;

  @override
  bool supportsInteraction = true;

  int cancellations = 0;

  @override
  void cancel() => cancellations++;

  int captures = 0;
  int selections = 0;
  int launches = 0;
  String? launchedApp;
  Completer<Uint8List>? blockedCapture;
  int pendingForegroundFailures = 0;
  String foregroundFailureCode = 'LAUNCHED_APP_NOT_FOREGROUND';

  @override
  Future<void> selectForegroundWindow() async {
    selections++;
    if (pendingForegroundFailures > 0) {
      pendingForegroundFailures--;
      throw ComputerUseException(
        foregroundFailureCode,
        'A test window is not ready for foreground selection.',
      );
    }
  }

  @override
  Future<void> openApplication(String application) async {
    launches++;
    launchedApp = application;
  }

  int clicks = 0;
  int typing = 0;
  int keys = 0;
  String? lastText;
  bool verifiedMarker = true;
  int markerChecks = 0;

  @override
  Future<bool> verifyTestMarker(String marker) async {
    markerChecks++;
    return verifiedMarker && lastText == marker;
  }

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
  group('Computer Use bounded smoke workflow', () {
    test('PASS requires verified app content, not just a tool call',
        () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final scenario = ComputerUseSmokeScenario(
        clock: () => DateTime.utc(2026, 11, 11),
        delay: (_) async {},
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isTrue);
      expect(result.code, 'VERIFIED');
      expect(adapter.launches, 1);
      expect(adapter.selections, 1);
      expect(adapter.typing, 1);
      expect(adapter.markerChecks, 1);
      expect(adapter.captures, 1);
    });

    test('verification failure never counts as PASS', () async {
      final adapter = FakeDesktop()..verifiedMarker = false;
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final scenario = ComputerUseSmokeScenario(
        delay: (_) async {},
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isFalse);
      expect(result.stage, 'verify');
      expect(result.code, 'VERIFICATION_FAILED');
      expect(adapter.captures, 0);
    });

    test('read-only session never launches the test application', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: false);
      final scenario = ComputerUseSmokeScenario();
      final result = await scenario.run(session: session);
      expect(result.passed, isFalse);
      expect(result.stage, 'authorization');
      expect(adapter.launches, 0);
    });

    test('STOP during wait prevents all subsequent input', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final scenario = ComputerUseSmokeScenario(
        delay: (_) async => session.stop(),
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isFalse);
      expect(result.code, 'SESSION_INACTIVE');
      expect(adapter.launches, 1);
      expect(adapter.typing, 0);
    });

    test('waits for a slow Notepad foreground without sending early input',
        () async {
      final adapter = FakeDesktop()..pendingForegroundFailures = 3;
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final scenario = ComputerUseSmokeScenario(
        delay: (_) async {},
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isTrue);
      expect(adapter.selections, 4);
      expect(adapter.typing, 1);
      expect(adapter.markerChecks, 1);
    });

    test('never types when an unrelated app retains foreground', () async {
      final adapter = FakeDesktop()..pendingForegroundFailures = 100;
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final scenario = ComputerUseSmokeScenario(
        delay: (_) async {},
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isFalse);
      expect(result.stage, 'select');
      expect(result.code, 'LAUNCHED_APP_NOT_FOREGROUND');
      expect(adapter.selections, 5);
      expect(adapter.typing, 0);
      expect(adapter.markerChecks, 0);
    });

    test('unexpected target error aborts without retries or typing', () async {
      final adapter = FakeDesktop()
        ..pendingForegroundFailures = 1
        ..foregroundFailureCode = 'TARGET_FOCUS_DENIED';
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final result = await ComputerUseSmokeScenario(
        delay: (_) async {},
      ).run(session: session);
      expect(result.passed, isFalse);
      expect(result.code, 'TARGET_FOCUS_DENIED');
      expect(adapter.selections, 1);
      expect(adapter.typing, 0);
    });

    test('STOP then regrant during launch wait cannot adopt new grant',
        () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      var waits = 0;
      final scenario = ComputerUseSmokeScenario(
        delay: (_) async {
          waits++;
          session.stop();
          session.beginSession(allowInteraction: true);
        },
      );
      final result = await scenario.run(session: session);
      expect(result.passed, isFalse);
      expect(result.stage, 'waiting');
      expect(result.code, 'SESSION_REVOKED');
      expect(waits, 1);
      expect(adapter.selections, 0);
      expect(adapter.typing, 0);
      expect(session.isActive, isTrue);
    });

    test('STOP during target retry blocks all remaining attempts', () async {
      final adapter = FakeDesktop()..pendingForegroundFailures = 10;
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      var waits = 0;
      final result = await ComputerUseSmokeScenario(
        delay: (_) async {
          waits++;
          if (waits == 2) session.stop();
        },
      ).run(session: session);
      expect(result.passed, isFalse);
      expect(result.stage, 'select');
      expect(result.code, 'SESSION_INACTIVE');
      expect(adapter.selections, 1);
      expect(adapter.typing, 0);
    });

    test('test marker verification rejects other text', () async {
      final adapter = FakeDesktop();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final result = await session.execute(<String, dynamic>{
        'action': 'verify_test_marker',
        'marker': 'password',
      });
      expect(result.error, 'INVALID_TEST_MARKER');
      expect(adapter.markerChecks, 0);
    });
  });

  group('ComputerUse observation-only capabilities', () {
    test('a read-only adapter never grants interactive access', () {
      final desktop = FakeDesktop()..supportsInteraction = false;
      final session = ComputerUseSession(adapter: desktop);
      expect(
        () => session.beginSession(allowInteraction: true),
        throwsA(
          isA<ComputerUseException>().having(
            (error) => error.code, 'code', 'INTERACTION_UNSUPPORTED',
          ),
        ),
      );
      expect(session.isActive, isFalse);
    });

    test('an observation-only adapter permits authorized observation',
        () async {
      final desktop = FakeDesktop()..supportsInteraction = false;
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: false);
      final observed = await session.execute(<String, dynamic>{
        'action': 'observe',
      });
      expect(observed.success, isTrue);
      final input = await session.execute(<String, dynamic>{
        'action': 'type_text',
        'text': 'not allowed',
      });
      expect(input.error, 'READ_ONLY_SESSION');
      expect(desktop.typing, 0);
    });
  });

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

    test('a regrant cannot adopt a screenshot from the old session',
        () async {
      final adapter = FakeDesktop();
      adapter.blockedCapture = Completer<Uint8List>();
      final session = ComputerUseSession(adapter: adapter);
      session.beginSession(allowInteraction: true);
      final revision = session.sessionRevision;
      final pending = session.execute(<String, dynamic>{'action': 'observe'});
      session.stop();
      session.beginSession(allowInteraction: true);
      expect(session.sessionRevision, isNot(revision));
      adapter.blockedCapture!.complete(FakeDesktop.validFrame());
      final oldResult = await pending;
      expect(oldResult.success, isFalse);
      expect(oldResult.error, 'SESSION_REVOKED');
      expect(session.isActive, isTrue);
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
      // STOP increments the session revision: an in-flight capture is stale.
      expect(finished.error, 'SESSION_REVOKED');
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
