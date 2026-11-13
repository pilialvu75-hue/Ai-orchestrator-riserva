import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_agent_runner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_local_json_planner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_accessibility_reader.dart';

final class FakeAccessibilityHost implements ComputerUseAdapter {
  @override
  bool get isSupported => true;

  @override
  void cancel() {}

  @override
  Future<Uint8List> capturePng() async => Uint8List(0);

  @override
  Future<void> click(int x, int y) async {}

  @override
  Future<void> typeText(String text) async {}

  @override
  Future<void> pressKey(String key) async {}

  @override
  Future<void> selectForegroundWindow() async {}

  @override
  Future<void> openApplication(String application) async {}

  @override
  Future<bool> verifyTestMarker(String marker) async => false;
}

final class RecordingAccessibilityDecisionModel
    implements ComputerUseLocalDecisionModel {
  int calls = 0;
  String? lastPayload;

  @override
  Future<String> completeLocally({
    required String systemInstruction,
    required String userPayload,
  }) async {
    calls++;
    lastPayload = userPayload;
    return '{"status":"act","action":"select_window_at",'
        '"arguments":{"x":40,"y":80}}';
  }
}

void main() {
  final frame = Uint8List(0);

  test('a trusted session can describe safe, bounded Windows controls',
      () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost())
      ..beginSession(allowInteraction: true);
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () async =>
          '{"sensitive":false,"description":"ControlType.Button (55,120) OK"}',
    );
    final summary = await reader.describe(frame);
    expect(summary.sensitive, isFalse);
    expect(summary.description, contains('ControlType.Button'));
  });

  test('no session prevents even starting an accessibility read', () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost());
    var calls = 0;
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () async {
        calls++;
        return '{"sensitive":false,"description":"irrelevant"}';
      },
    );
    await expectLater(
      reader.describe(frame),
      throwsA(isA<ComputerUseException>()
          .having((error) => error.code, 'code', 'SESSION_INACTIVE')),
    );
    expect(calls, 0);
  });

  test('password controls never reach the local planner', () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost())
      ..beginSession(allowInteraction: false);
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () async =>
          '{"sensitive":true,"description":"Confidential input"}',
    );
    final summary = await reader.describe(frame);
    expect(summary.sensitive, isTrue);
    expect(summary.description, isEmpty);
  });

  test('malformed and sensitivity-suspect summaries fail closed', () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost())
      ..beginSession(allowInteraction: true);
    var payload = '{broken';
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () async => payload,
    );
    expect((await reader.describe(frame)).sensitive, isTrue);
    payload = '{"sensitive":false,"description":"Enter password"}';
    expect((await reader.describe(frame)).sensitive, isTrue);
    payload = '{"sensitive":false,"description":"' + List<String>.filled(6001, 'x').join() + '"}';
    expect((await reader.describe(frame)).sensitive, isTrue);
    payload = '{"sensitive":false,"description":5}';
    expect((await reader.describe(frame)).sensitive, isTrue);
  });

  test('LOCAL planner gets only safe accessibility summary', () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost())
      ..beginSession(allowInteraction: true);
    var sensitive = false;
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () async => sensitive
          ? '{"sensitive":true,"description":""}'
          : '{"sensitive":false,'
              '"description":"ControlType.Button (40,80) Start"}',
    );
    final model = RecordingAccessibilityDecisionModel();
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: reader,
      model: model,
    );
    const goal = 'Select visible test control';
    ComputerUseAgentObservation observe() => ComputerUseAgentObservation(
      goal: goal,
      framePng: frame,
      step: 0,
      lastAction: null,
      lastError: null,
    );
    final decision = await planner.decide(observe());
    expect(decision.action, 'select_window_at');
    expect(decision.arguments['x'], 40);
    final payload = jsonDecode(model.lastPayload!) as Map<String, dynamic>;
    expect(payload['screen_description'],
        'ControlType.Button (40,80) Start');
    expect(model.calls, 1);

    sensitive = true;
    final aborted = await planner.decide(observe());
    expect(aborted.isAbort, isTrue);
    expect(model.calls, 1);
  });

  test('STOP and new consent cannot adopt old accessibility output', () async {
    final session = ComputerUseSession(adapter: FakeAccessibilityHost())
      ..beginSession(allowInteraction: true);
    final pending = Completer<String>();
    final reader = WindowsComputerUseAccessibilityReader(
      session: session,
      captureAccessibilityJson: () => pending.future,
    );
    final result = reader.describe(frame);
    await Future<void>.delayed(Duration.zero);
    session.stop();
    session.beginSession(allowInteraction: true);
    pending.complete(
      '{"sensitive":false,"description":"ControlType.Button (10,20) Old"}',
    );
    await expectLater(
      result,
      throwsA(isA<ComputerUseException>()
          .having((error) => error.code, 'code', 'SESSION_REVOKED')),
    );
  });
}
