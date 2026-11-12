/// Independent, read-only 2048 scoreboard parser for Computer Use QA.
/// It reads the *observed* Windows accessibility summary, never model output.
final class ComputerUse2048Benchmark {
  const ComputerUse2048Benchmark({
    required this.score,
    required this.bestTile,
    required this.moves,
    required this.state,
    required this.board,
  });

  final int score;
  final int bestTile;
  final int moves;
  final String state;
  final List<int> board;

  bool get reachedTarget => bestTile >= 64;

  /// A game claim is valid only with the exact 4x4 tile set and a matching
  /// scoreboard. Partial/ambiguous UI Automation trees are not accepted.
  static ComputerUse2048Benchmark? parse(String accessibilitySummary) {
    if (accessibilitySummary.isEmpty || accessibilitySummary.length > 6000) {
      return null;
    }
    final hudMatches = _hud.allMatches(accessibilitySummary).toList();
    if (hudMatches.length != 1) return null;
    final hud = hudMatches.single;
    final score = int.tryParse(hud.group(1)!);
    final best = int.tryParse(hud.group(2)!);
    final moves = int.tryParse(hud.group(3)!);
    final state = hud.group(4)!;
    if (score == null || best == null || moves == null ||
        score > 1000000000 || moves > 10000000 ||
        best < 2 || best > 131072 ||
        !_isTile(best) ||
        (state == 'TARGET 64 REACHED' && best < 64) ||
        (state == 'PLAYING' && best >= 64)) {
      return null;
    }

    final board = List<int>.filled(16, -1);
    var seen = 0;
    for (final tile in _tile.allMatches(accessibilitySummary)) {
      final row = int.tryParse(tile.group(1)!);
      final col = int.tryParse(tile.group(2)!);
      final value = int.tryParse(tile.group(3)!);
      if (row == null || col == null || value == null ||
          row < 1 || row > 4 || col < 1 || col > 4 ||
          value > 131072 || !_isTile(value)) {
        return null;
      }
      final index = (row - 1) * 4 + (col - 1);
      if (board[index] != -1) return null;
      board[index] = value;
      seen++;
    }
    if (seen != 16 ||
        !board.contains(best) ||
        board.every((value) => value == 0)) {
      return null;
    }
    if (state == 'GAME OVER' && _hasLegalMove(board)) return null;
    return ComputerUse2048Benchmark(
      score: score,
      bestTile: best,
      moves: moves,
      state: state,
      board: List<int>.unmodifiable(board),
    );
  }

  static bool _isTile(int tile) =>
      tile == 0 || (tile > 0 && (tile & (tile - 1)) == 0);

  static bool _hasLegalMove(List<int> board) {
    for (var i = 0; i < 16; i++) {
      if (board[i] == 0) return true;
      if (i % 4 < 3 && board[i] == board[i + 1]) return true;
      if (i ~/ 4 < 3 && board[i] == board[i + 4]) return true;
    }
    return false;
  }

  static final RegExp _hud = RegExp(
    r'2048 score ([0-9]+) best tile ([0-9]+) '
    r'moves ([0-9]+) state (PLAYING|TARGET 64 REACHED|GAME OVER)',
  );

  static final RegExp _tile = RegExp(
    r'2048 tile row ([0-9]+) column ([0-9]+) value ([0-9]+)',
  );
}
