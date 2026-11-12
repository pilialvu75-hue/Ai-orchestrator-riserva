import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_benchmark.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_experience.dart';

ComputerUse2048Benchmark snapshot({
  required List<int> board,
  required int score,
  required int moves,
  int best = 2,
}) => ComputerUse2048Benchmark(
  score: score,
  bestTile: best,
  moves: moves,
  state: best >= 64 ? 'TARGET 64 REACHED' : 'PLAYING',
  board: List<int>.unmodifiable(board),
);

void main() {
  final initial = snapshot(
    board: <int>[2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    score: 0,
    moves: 0,
  );
  final moved = snapshot(
    board: <int>[0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    score: 0,
    moves: 1,
  );

  test('pairs only a model move with the next observed 2048 frame', () {
    final collector = ComputerUse2048ExperienceCollector();
    collector.proposedMove(step: 0, before: initial, move: 'right');
    collector.observedAfter(step: 1, after: moved);
    expect(collector.samples, hasLength(1));
    final sample = collector.samples.single;
    expect(sample.move, 'right');
    expect(sample.reward, 0);
    expect(sample.stateChanged, isTrue);
    expect(sample.moveObserved, isTrue);
    expect(collector.observedMoves, 1);

    final json = sample.toCandidateJson();
    expect(json['candidate_only'], true);
    expect(json['schema'], 'aivexus.qa2048.experience.v1');
    expect(json['before_board'], initial.board);
    expect(json['after_board'], moved.board);
    expect(json.keys, isNot(contains('screenshot')));
    expect(json.keys, isNot(contains('prompt')));
    expect(json.keys, isNot(contains('account')));
  });

  test('does not pair late observations with unrelated actions', () {
    final collector = ComputerUse2048ExperienceCollector();
    collector.proposedMove(step: 0, before: initial, move: 'left');
    collector.observedAfter(step: 2, after: moved);
    expect(collector.samples, isEmpty);
    collector.proposedMove(step: 1, before: initial, move: 'right');
    collector.observedAfter(step: 1, after: moved);
    expect(collector.samples, isEmpty);
    collector.observedAfter(step: 2, after: moved);
    expect(collector.samples, hasLength(1));
    collector.observedAfter(step: 2, after: moved);
    expect(collector.samples, hasLength(1));
  });

  test('rejects reset, multi-move jumps and invalid model directions', () {
    final collector = ComputerUse2048ExperienceCollector();
    collector.proposedMove(step: 0, before: moved, move: 'click');
    collector.observedAfter(step: 1, after: initial);
    expect(collector.samples, isEmpty);

    collector.proposedMove(step: 0, before: moved, move: 'up');
    collector.observedAfter(step: 1, after: initial);
    expect(collector.samples, isEmpty);

    final twoMoves = snapshot(
      board: moved.board,
      score: 10,
      moves: 3,
    );
    collector.proposedMove(step: 1, before: moved, move: 'down');
    collector.observedAfter(step: 2, after: twoMoves);
    expect(collector.samples, isEmpty);
  });

  test('records no-effect actions honestly, not as verified progress', () {
    final collector = ComputerUse2048ExperienceCollector();
    collector.proposedMove(step: 0, before: initial, move: 'down');
    collector.observedAfter(step: 1, after: initial);
    expect(collector.samples.single.stateChanged, isFalse);
    expect(collector.samples.single.moveObserved, isFalse);
    expect(collector.changedBoards, 0);
    expect(collector.observedMoves, 0);
  });

  test('is bounded, read-only to callers and resettable on STOP', () {
    final collector = ComputerUse2048ExperienceCollector(maxTransitions: 1);
    collector.proposedMove(step: 0, before: initial, move: 'right');
    collector.observedAfter(step: 1, after: moved);
    collector.proposedMove(step: 1, before: moved, move: 'up');
    collector.observedAfter(step: 2, after: moved);
    expect(collector.samples, hasLength(1));
    expect(
      () => collector.samples.clear(),
      throwsUnsupportedError,
    );
    collector.reset();
    expect(collector.samples, isEmpty);
    collector.observedAfter(step: 1, after: moved);
    expect(collector.samples, isEmpty);
  });
}
