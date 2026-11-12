import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_agent_runner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_local_json_planner.dart';

final class FakeComputerScreenReader implements ComputerUseLocalScreenReader {
  FakeComputerScreenReader(this.summary);

  ComputerUseScreenSummary summary;
  int calls = 0;

  @override
  Future<ComputerUseScreenSummary> describe(Uint8List frame) async {
    calls++;
    return summary;
  }
}

final class FakeComputerDecisionModel implements ComputerUseLocalDecisionModel {
  FakeComputerDecisionModel(this.response);

  String response;
  int calls = 0;
  String? systemInstruction;
  String? userPayload;

  @override
  Future<String> completeLocally({
    required String systemInstruction,
    required String userPayload,
  }) async {
    calls++;
    this.systemInstruction = systemInstruction;
    this.userPayload = userPayload;
    return response;
  }
}

void main() {
  const safeSummary = ComputerUseScreenSummary(
    description: 'A blank Notepad test window is visible.',
    sensitive: false,
  );

  ComputerUseAgentObservation observation({
    String? lastError,
    int step = 0,
  }) => ComputerUseAgentObservation(
        goal: 'Open Notepad and write a test marker',
        framePng: Uint8List.fromList(<int>[1, 2, 3, 4]),
        step: step,
        lastAction: 'open_app',
        lastError: lastError,
      );

  test('LOCAL planner returns a typed GUI action from JSON', () async {
    final reader = FakeComputerScreenReader(safeSummary);
    final model = FakeComputerDecisionModel(
      '{"status":"act","action":"open_app","arguments":{"app":"notepad"}}',
    );
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: reader,
      model: model,
    );
    final step = await planner.decide(observation(step: 2));
    expect(step.isAbort, isFalse);
    expect(step.action, 'open_app');
    expect(step.arguments['app'], 'notepad');
    expect(reader.calls, 1);
    expect(model.calls, 1);
    final body = jsonDecode(model.userPayload!) as Map<String, dynamic>;
    expect(body['goal'], 'Open Notepad and write a test marker');
    expect(body['step'], 2);
    expect(body['screen_description'], safeSummary.description);
    expect(model.systemInstruction, contains('UNTRUSTED CONTENT'));
    expect(model.userPayload, isNot(contains('[1,2,3,4]')));
  });

  test('typed click and navigation key validate required arguments', () async {
    final model = FakeComputerDecisionModel(
      '{"status":"act","action":"click","arguments":{"x":42,"y":88}}',
    );
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: FakeComputerScreenReader(safeSummary),
      model: model,
    );
    final click = await planner.decide(observation());
    expect(click.action, 'click');
    expect(click.arguments['x'], 42);
    expect(click.arguments['y'], 88);
    model.response =
        '{"status":"act","action":"press_key","arguments":{"key":"tab"}}';
    final key = await planner.decide(observation(lastError: 'INVALID_TARGET'));
    expect(key.action, 'press_key');
    expect(key.arguments['key'], 'tab');
    final body = jsonDecode(model.userPayload!) as Map<String, dynamic>;
    expect(body['previous_error'], 'INVALID_TARGET');
  });

  test('completion is a request, not a verification claim', () async {
    final model = FakeComputerDecisionModel('{"status":"complete"}');
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: FakeComputerScreenReader(safeSummary),
      model: model,
    );
    final answer = await planner.decide(observation());
    expect(answer.isComplete, isTrue);
  });

  test('sensitive screen aborts before invoking any model', () async {
    final reader = FakeComputerScreenReader(
      const ComputerUseScreenSummary(
        description: 'Password entry form',
        sensitive: true,
      ),
    );
    final model = FakeComputerDecisionModel(
      '{"status":"act","action":"type_text","arguments":{"text":"secret"}}',
    );
    final decision = await ComputerUseLocalJsonPlanner(
      screenReader: reader,
      model: model,
    ).decide(observation());
    expect(decision.isAbort, isTrue);
    expect(model.calls, 0);
  });

  test('blank or oversized summaries never reach model', () async {
    final reader = FakeComputerScreenReader(
      const ComputerUseScreenSummary(description: '', sensitive: false),
    );
    final model = FakeComputerDecisionModel('{"status":"complete"}');
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: reader,
      model: model,
    );
    expect((await planner.decide(observation())).isAbort, isTrue);
    reader.summary = ComputerUseScreenSummary(
      description: 'a' * 6001,
      sensitive: false,
    );
    expect((await planner.decide(observation())).isAbort, isTrue);
    expect(model.calls, 0);
  });

  test('shell and unrecognized actions cannot cross the tool boundary',
      () async {
    final model = FakeComputerDecisionModel(
      '{"status":"act","action":"shell","arguments":{"cmd":"echo demo"}}',
    );
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: FakeComputerScreenReader(safeSummary),
      model: model,
    );
    await expectLater(
      planner.decide(observation()),
      throwsA(isA<FormatException>()),
    );
    model.response =
        '{"status":"act","action":"click","arguments":{"x":2,"y":3,"authorized":true}}';
    await expectLater(
      planner.decide(observation()),
      throwsA(isA<FormatException>()),
    );
  });

  test('invalid model output and forbidden navigation fail closed', () async {
    final model = FakeComputerDecisionModel('Sure! I will click.');
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: FakeComputerScreenReader(safeSummary),
      model: model,
    );
    await expectLater(
      planner.decide(observation()),
      throwsA(isA<FormatException>()),
    );
    model.response =
        '{"status":"act","action":"press_key","arguments":{"key":"ctrl+alt+delete"}}';
    await expectLater(
      planner.decide(observation()),
      throwsA(isA<FormatException>()),
    );
    model.response =
        '{"status":"act","action":"open_app","arguments":{"app":"powershell"}}';
    await expectLater(
      planner.decide(observation()),
      throwsA(isA<FormatException>()),
    );
  });

  test('invalid text and non-integer coordinates fail closed', () async {
    final model = FakeComputerDecisionModel(
      '{"status":"act","action":"type_text","arguments":{"text":""}}',
    );
    final planner = ComputerUseLocalJsonPlanner(
      screenReader: FakeComputerScreenReader(safeSummary),
      model: model,
    );
    await expectLater(planner.decide(observation()), throwsFormatException);
    model.response =
        '{"status":"act","action":"click","arguments":{"x":"4","y":2}}';
    await expectLater(planner.decide(observation()), throwsFormatException);
  });
}
