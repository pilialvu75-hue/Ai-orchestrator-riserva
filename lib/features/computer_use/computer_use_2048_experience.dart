import 'dart:collection';

import 'package:ai_orchestrator/features/computer_use/computer_use_2048_benchmark.dart';

/// A bounded, ephemeral example of what a real LOCAL model tried in the QA
/// 2048 game and what the independent window reader observed afterwards.
///
/// No pixels, account identifiers, prompts, filenames, or free-form text are
/// retained. These are *candidates* for future learning, NOT model training.
final class ComputerUse2048Experience {
  ComputerUse2048Experience({
    required this.step,
    required this.before,
    required this.move,
    required this.after,
  });

  final int step;
  final ComputerUse2048Benchmark before;
  final String move;
  final ComputerUse2048Benchmark after;

  int get reward => after.score - before.score;
  bool get stateChanged => !_sameBoard(before.board, after.board);
  bool get moveObserved => after.moves == before.moves + 1;
  bool get reachedTarget => after.reachedTarget;

  /// Schema has no screenshots or personal content, and deliberately makes
  /// no assertion that a reward means the model learned anything.
  Map<String, Object> toCandidateJson() =>
      Map<String, Object>.unmodifiable(<String, Object>{
        'schema': 'aivexus.qa2048.experience.v1',
        'candidate_only': true,
        'step': step,
        'before_board': List<int>.of(before.board, growable: false),
        'move': move,
        'after_board': List<int>.of(after.board, growable: false),
        'score_before': before.score,
        'score_after': after.score,
        'score_delta': reward,
        'moves_before': before.moves,
        'moves_after': after.moves,
        'state_changed': stateChanged,
        'move_observed': moveObserved,
        'target_verified': reachedTarget,
      });

  static bool _sameBoard(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Pairs a model-proposed move with exactly the next independent observation.
/// Failed or skipped tool actions must not be mistaken for successful moves.
/// No disk/network I/O, training, or automatic sharing is performed.
final class ComputerUse2048ExperienceCollector {
  ComputerUse2048ExperienceCollector({this.maxTransitions = 100})
      : assert(maxTransitions > 0 && maxTransitions <= 1000);

  final int maxTransitions;
  final List<ComputerUse2048Experience> _samples =
      <ComputerUse2048Experience>[];
  int? _pendingStep;
  ComputerUse2048Benchmark? _pendingBefore;
  String? _pendingMove;

  List<ComputerUse2048Experience> get samples =>
      UnmodifiableListView<ComputerUse2048Experience>(_samples);

  int get observedMoves => _samples.where((s) => s.moveObserved).length;
  int get changedBoards => _samples.where((s) => s.stateChanged).length;

  void proposedMove({
    required int step,
    required ComputerUse2048Benchmark before,
    required String move,
  }) {
    _clearPending();
    if (_samples.length >= maxTransitions ||
        step < 0 ||
        !const <String>{'left', 'right', 'up', 'down'}.contains(move)) {
      return;
    }
    _pendingStep = step;
    _pendingBefore = before;
    _pendingMove = move;
  }

  void observedAfter({
    required int step,
    required ComputerUse2048Benchmark after,
  }) {
    final before = _pendingBefore;
    final move = _pendingMove;
    final pendingStep = _pendingStep;
    if (before == null || move == null || pendingStep == null ||
        step != pendingStep + 1) {
      return;
    }
    _clearPending();

    // A reset, skipped frame or multi-move jump is not a trustworthy
    // single-action training transition. Preserve only bounded observations.
    if (after.moves < before.moves ||
        after.moves > before.moves + 1 ||
        after.score < before.score ||
        _samples.length >= maxTransitions) {
      return;
    }
    _samples.add(ComputerUse2048Experience(
      step: pendingStep,
      before: before,
      move: move,
      after: after,
    ));
  }

  void reset() {
    _samples.clear();
    _clearPending();
  }

  void _clearPending() {
    _pendingStep = null;
    _pendingBefore = null;
    _pendingMove = null;
  }
}
