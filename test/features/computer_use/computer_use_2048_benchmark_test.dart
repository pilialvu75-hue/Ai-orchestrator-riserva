import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_benchmark.dart';

String gameSummary(List<int> board, {
  int score = 0,
  int best = 2,
  int moves = 0,
  String state = 'PLAYING',
}) {
  final rows = <String>[
    'ControlType.Button (25,55) 2048 score $score best tile $best '
        'moves $moves state $state',
  ];
  for (var i = 0; i < 16; i++) {
    final row = i ~/ 4 + 1;
    final col = i % 4 + 1;
    rows.add('ControlType.Button (25,100) 2048 tile row $row '
        'column $col value ${board[i]}');
  }
  return rows.join('\n');
}

void main() {
  test('reads the actual board and baseline game metrics', () {
    final board = <int>[2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    final progress = ComputerUse2048Benchmark.parse(gameSummary(board));
    expect(progress, isNotNull);
    expect(progress!.score, 0);
    expect(progress.moves, 0);
    expect(progress.bestTile, 2);
    expect(progress.reachedTarget, isFalse);
    expect(progress.board, board);
  });

  test('verifies reaching tile 64 from a complete observed board', () {
    final board = <int>[64, 2, 0, 0, 0, 4, 0, 0, 0, 0, 8, 0, 0, 0, 0, 2];
    final progress = ComputerUse2048Benchmark.parse(
      gameSummary(board, score: 348, best: 64,
          moves: 57, state: 'TARGET 64 REACHED'),
    );
    expect(progress, isNotNull);
    expect(progress!.score, 348);
    expect(progress.reachedTarget, isTrue);
  });

  test('rejects incomplete or duplicated tile snapshots', () {
    final board = <int>[2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    final full = gameSummary(board);
    expect(ComputerUse2048Benchmark.parse(
      full.split('\n').skip(1).join('\n')), isNull);
    expect(ComputerUse2048Benchmark.parse(
      full.split('\n').skip(1).skip(1).join('\n')), isNull);
    expect(ComputerUse2048Benchmark.parse(
      '$full\nControlType.Button (25,100) '
      '2048 tile row 1 column 1 value 2'), isNull);
  });

  test('rejects impossible scoreboards and malformed tile values', () {
    final board = <int>[2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    expect(ComputerUse2048Benchmark.parse(
      gameSummary(board, best: 64)), isNull);
    expect(ComputerUse2048Benchmark.parse(
      gameSummary(board, best: 2, state: 'TARGET 64 REACHED')), isNull);
    expect(ComputerUse2048Benchmark.parse(
      gameSummary(board, best: 2, state: 'GAME OVER')), isNull);
    final bad = <int>[3, ...board.skip(1)];
    expect(ComputerUse2048Benchmark.parse(gameSummary(bad)), isNull);
  });

  test('accepts genuinely blocked game-over positions only', () {
    final board = <int>[
      2, 4, 2, 4,
      4, 2, 4, 2,
      2, 4, 2, 4,
      4, 2, 4, 2,
    ];
    final progress = ComputerUse2048Benchmark.parse(
      gameSummary(board, score: 120, best: 4, moves: 84,
          state: 'GAME OVER'),
    );
    expect(progress?.state, 'GAME OVER');
    final notOver = List<int>.of(board)..[0] = 0;
    expect(ComputerUse2048Benchmark.parse(
      gameSummary(notOver, score: 120, best: 4, moves: 84,
          state: 'GAME OVER')), isNull);
  });
}
