import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_benchmark.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_local_agent.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_agent_runner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_local_json_planner.dart';

String summary2048({
  int bestTile = 2,
  int score = 0,
  int moves = 0,
  bool valid = true,
}) {
  if (!valid) return 'ControlType.Button Some other application';
  final board = <int>[
    bestTile, 2, 0, 0,
    0, 2, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
  ];
  final state = bestTile >= 64 ? 'TARGET 64 REACHED' : 'PLAYING';
  final lines = <String>[
    'ControlType.Button (30,55) 2048 score $score '
        'best tile $bestTile moves $moves state $state',
  ];
  for (var i = 0; i < 16; i++) {
    lines.add('ControlType.Button (22,100) 2048 tile row '
        '${i ~/ 4 + 1} column ${i % 4 + 1} value ${board[i]}');
  }
  return lines.join('\n');
}

final class Stub2048Reader implements ComputerUseLocalScreenReader {
  Stub2048Reader(this.summary);

  ComputerUseScreenSummary summary;
  int calls = 0;

  @override
  Future<ComputerUseScreenSummary> describe(Uint8List framePng) async {
    calls++;
    return summary;
  }
}

final class Stub2048Model
    implements ComputerUseLocalDecisionModel, ComputerUseCancellableDecisionModel {
  Stub2048Model(this.answer);

  String answer;
  int calls = 0;
  int cancels = 0;
  String? lastPayload;

  @override
  Future<String> completeLocally({
    required String systemInstruction,
    required String userPayload,
  }) async {
    calls++;
    lastPayload = userPayload;
    return answer;
  }

  @override
  void cancelPendingCompletion() => cancels++;
}

ComputerUseAgentObservation observation() => ComputerUseAgentObservation(
  goal: 'Play 2048',
  framePng: Uint8List(0),
  step: 0,
  lastAction: null,
  lastError: null,
);

void main() {
  test('local model reads 4x4 game and selects one safe keyboard direction',
      () async {
    final reader = Stub2048Reader(
      ComputerUseScreenSummary(
        description: summary2048(score: 16, moves: 4),
        sensitive: false,
      ),
    );
    final model = Stub2048Model('{"move":"left"}');
    final planner = ComputerUse2048LocalPlanner(
      screenReader: reader, model: model,
    );
    final action = await planner.decide(observation());
    expect(action.action, 'press_key');
    expect(action.arguments, <String, dynamic>{'key': 'left'});
    expect(model.calls, 1);
    final payload = jsonDecode(model.lastPayload!) as Map<String, dynamic>;
    final rows = payload['board'] as List<dynamic>;
    expect(rows.length, 4);
    expect((rows[0] as List<dynamic>).length, 4);
    expect(payload['score'], 16);
    expect(payload['moves'], 4);
    expect(payload['best_tile'], 2);
    expect(ComputerUse2048LocalPlanner.instruction, contains('ONLY'));
  });

  test('fenced single JSON from a small LOCAL model is allowed', () async {
    final reader = Stub2048Reader(ComputerUseScreenSummary(
      description: summary2048(), sensitive: false,
    ));
    final model = Stub2048Model('```json\n{"move":"up"}\n```');
    final planner = ComputerUse2048LocalPlanner(
      screenReader: reader, model: model,
    );
    final decision = await planner.decide(observation());
    expect(decision.action, 'press_key');
    expect(decision.arguments['key'], 'up');
    model.answer = '```json\n{"move":"up","action":"shell"}\n```';
    await expectLater(planner.decide(observation()),
        throwsA(isA<FormatException>()));
    model.answer = 'Please do this: ```json\n{"move":"up"}\n```';
    await expectLater(planner.decide(observation()),
        throwsA(isA<FormatException>()));
  });

  test('rejects model output that is not a single valid move', () async {
    final reader = Stub2048Reader(ComputerUseScreenSummary(
      description: summary2048(), sensitive: false,
    ));
    final model = Stub2048Model('{"move":"left","cmd":"powershell"}');
    final planner = ComputerUse2048LocalPlanner(
      screenReader: reader, model: model,
    );
    for (final invalid in <String>[
      '{"move":"left","cmd":"powershell"}',
      '{"move":"delete"}',
      '{"action":"open_app","app":"paint"}',
      'left',
      '{"move":1}',
    ]) {
      model.answer = invalid;
      await expectLater(
        planner.decide(observation()),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('sensitive, unrelated or game-over screens stop before model call',
      () async {
    final reader = Stub2048Reader(
      const ComputerUseScreenSummary(description: '', sensitive: true),
    );
    final model = Stub2048Model('{"move":"right"}');
    final planner = ComputerUse2048LocalPlanner(
      screenReader: reader, model: model,
    );
    expect((await planner.decide(observation())).isAbort, isTrue);
    reader.summary = ComputerUseScreenSummary(
      description: summary2048(valid: false), sensitive: false,
    );
    expect((await planner.decide(observation())).isAbort, isTrue);
    expect(model.calls, 0);
  });

  test('independent verifier accepts score only if observed tile reaches 64',
      () async {
    final reader = Stub2048Reader(ComputerUseScreenSummary(
      description: summary2048(bestTile: 2),
      sensitive: false,
    ));
    ComputerUse2048Benchmark? observed;
    final verifier = ComputerUse2048LocalVerifier(
      screenReader: reader,
      onObservation: (result) => observed = result,
    );
    expect(await verifier.isSatisfied(observation()), isFalse);
    expect(observed?.bestTile, 2);
    reader.summary = ComputerUseScreenSummary(
      description: summary2048(bestTile: 64, score: 320, moves: 30),
      sensitive: false,
    );
    expect(await verifier.isSatisfied(observation()), isTrue);
    expect(observed?.score, 320);
    reader.summary = const ComputerUseScreenSummary(
      description: '', sensitive: true,
    );
    expect(await verifier.isSatisfied(observation()), isFalse);
  });

  test('STOP reaches active local decision model', () {
    final reader = Stub2048Reader(ComputerUseScreenSummary(
      description: summary2048(), sensitive: false,
    ));
    final model = Stub2048Model('{"move":"up"}');
    final planner = ComputerUse2048LocalPlanner(
      screenReader: reader, model: model,
    );
    planner.cancel();
    expect(model.cancels, 1);
  });
}
