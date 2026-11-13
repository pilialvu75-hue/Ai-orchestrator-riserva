import 'dart:async';
import 'dart:typed_data';

import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// A screenshot and minimal, non-sensitive task history. Keep this on-device
/// until a distinct, user-authorized Cloud vision transport is implemented.
final class ComputerUseAgentObservation {
  const ComputerUseAgentObservation({
    required this.goal,
    required this.framePng,
    required this.step,
    required this.lastAction,
    required this.lastError,
  });

  final String goal;
  final Uint8List framePng;
  final int step;
  final String? lastAction;
  final String? lastError;
}

/// Planner output is data, never a command line or executable program.
/// The planner chooses the next action dynamically after every observation.
final class ComputerUseAgentDecision {
  const ComputerUseAgentDecision.act(this.action, this.arguments)
      : isComplete = false,
        isAbort = false;

  const ComputerUseAgentDecision.complete()
      : action = '',
        arguments = const <String, dynamic>{},
        isComplete = true,
        isAbort = false;

  const ComputerUseAgentDecision.abort()
      : action = '',
        arguments = const <String, dynamic>{},
        isComplete = false,
        isAbort = true;

  final String action;
  final Map<String, dynamic> arguments;
  final bool isComplete;
  final bool isAbort;
}

/// Implement with an authorized LOCAL planner first; Cloud needs a separate
/// explicit screenshot-transfer grant. No provider is called by this class.
abstract interface class ComputerUseAgentPlanner {
  Future<ComputerUseAgentDecision> decide(
    ComputerUseAgentObservation observation,
  );
}

/// Optional cancellation hook: STOP must also abort LOCAL inference, not
/// merely ignore the model's eventual answer.
abstract interface class ComputerUseCancellablePlanner {
  void cancel();
}

/// Independent goal verifier. The planner's claim of completion is NOT proof.
abstract interface class ComputerUseAgentVerifier {
  Future<bool> isSatisfied(ComputerUseAgentObservation observation);
}

enum ComputerUseAgentOutcome {
  verified,
  unauthorized,
  stopped,
  maxSteps,
  repeatedAction,
  timeout,
  plannerError,
  verifierError,
  busy,
}

final class ComputerUseAgentResult {
  const ComputerUseAgentResult({
    required this.outcome,
    required this.steps,
    this.lastError,
  });

  final ComputerUseAgentOutcome outcome;
  final int steps;

  /// Only a diagnostic code; never include screen contents or typed text.
  final String? lastError;
}

/// Observe -> think -> typed GUI action -> re-observe -> independent verify.
///
/// This runner is usable with a fake planner/verifier while the real Aivexus
/// inference runtime is unavailable. No model/provider is instantiated here.
/// The user must first authorize a ComputerUseSession via trusted UI.
final class ComputerUseAgentRunner {
  ComputerUseAgentRunner({
    required ComputerUseSession session,
    required ComputerUseAgentPlanner planner,
    required ComputerUseAgentVerifier verifier,
    this.maxSteps = 12,
    this.maxConsecutiveIdenticalActions = 3,
    this.maxDuration = const Duration(minutes: 2),
    this.operationTimeout = const Duration(seconds: 25),
  })  : assert(maxSteps > 0 && maxSteps <= 100),
        assert(maxConsecutiveIdenticalActions == 0 ||
            maxConsecutiveIdenticalActions >= 2),
        assert(maxDuration > Duration.zero),
        assert(operationTimeout > Duration.zero),
        _session = session,
        _planner = planner,
        _verifier = verifier;

  final ComputerUseSession _session;
  final ComputerUseAgentPlanner _planner;
  final ComputerUseAgentVerifier _verifier;
  final int maxSteps;
  /// 0 disables only the identical-action heuristic. Useful for 2048 where
  /// repeated arrow keys can be valid moves on a changing board. The overall
  /// step/time limits and independent verifier always remain active.
  final int maxConsecutiveIdenticalActions;
  final Duration maxDuration;
  final Duration operationTimeout;

  bool _running = false;

  bool get isRunning => _running;

  /// Revokes authorization and stops host operations. Planner results that
  /// arrive after this call cannot re-use a freshly granted session.
  void stop() {
    _session.stop();
    if (_planner is ComputerUseCancellablePlanner) {
      (_planner as ComputerUseCancellablePlanner).cancel();
    }
  }

  Future<ComputerUseAgentResult> run({
    required String goal,
    void Function(String stage, int step)? onStage,
  }) async {
    if (_running) {
      return const ComputerUseAgentResult(
        outcome: ComputerUseAgentOutcome.busy,
        steps: 0,
      );
    }
    if (goal.trim().isEmpty || goal.length > 2000 ||
        !_session.canInteract) {
      return const ComputerUseAgentResult(
        outcome: ComputerUseAgentOutcome.unauthorized,
        steps: 0,
      );
    }
    _running = true;
    final revision = _session.sessionRevision;
    final timer = Stopwatch()..start();
    var steps = 0;
    String? lastAction;
    String? lastError;
    String? lastSignature;
    var repeats = 0;

    bool authorized() =>
        _session.canInteract && _session.sessionRevision == revision;

    ComputerUseAgentResult finish(
      ComputerUseAgentOutcome outcome, [String? error]
    ) =>
        ComputerUseAgentResult(
          outcome: outcome,
          steps: steps,
          lastError: error ?? lastError,
        );

    Duration remaining() {
      final left = maxDuration - timer.elapsed;
      return left < operationTimeout ? left : operationTimeout;
    }

    Future<T> within<T>(Future<T> future) {
      final limit = remaining();
      if (limit <= Duration.zero) throw TimeoutException('Goal deadline');
      return future.timeout(limit);
    }

    try {
      while (steps < maxSteps) {
        if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
        if (timer.elapsed >= maxDuration) {
          stop();
          return finish(ComputerUseAgentOutcome.timeout);
        }

        onStage?.call('observe', steps);
        final Uint8List frame;
        try {
          frame = await within(_session.captureFrame());
        } on TimeoutException {
          stop();
          return finish(ComputerUseAgentOutcome.timeout);
        } on ComputerUseException catch (e) {
          return finish(ComputerUseAgentOutcome.stopped, e.code);
        }
        if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
        final observation = ComputerUseAgentObservation(
          goal: goal.trim(),
          framePng: frame,
          step: steps,
          lastAction: lastAction,
          lastError: lastError,
        );

        onStage?.call('plan', steps);
        final ComputerUseAgentDecision decision;
        try {
          decision = await within(_planner.decide(observation));
        } on TimeoutException {
          stop();
          return finish(ComputerUseAgentOutcome.timeout);
        } catch (_) {
          return finish(ComputerUseAgentOutcome.plannerError, 'PLANNER_ERROR');
        }
        if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);

        if (decision.isAbort) {
          return finish(ComputerUseAgentOutcome.stopped);
        }
        if (decision.isComplete) {
          // A model's "done" is never accepted without an independent check.
          onStage?.call('verify', steps);
          try {
            if (await within(_verifier.isSatisfied(observation))) {
              if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
              return finish(ComputerUseAgentOutcome.verified);
            }
            lastError = 'GOAL_UNVERIFIED';
            steps++;
            continue;
          } on TimeoutException {
            stop();
            return finish(ComputerUseAgentOutcome.timeout);
          } catch (_) {
            return finish(ComputerUseAgentOutcome.verifierError,
                'VERIFIER_ERROR');
          }
        }

        if (!_allowedActions.contains(decision.action)) {
          lastError = 'ACTION_NOT_ALLOWED';
          steps++;
          continue;
        }

        // A model cannot smuggle a different action inside arguments.
        final params = Map<String, dynamic>.of(decision.arguments)
          ..['action'] = decision.action;
        // Never include plaintext typing in history or diagnostic callbacks.
        final signature = _actionSignature(decision.action, params);
        repeats = signature == lastSignature ? repeats + 1 : 1;
        lastSignature = signature;
        if (maxConsecutiveIdenticalActions > 0 &&
            repeats >= maxConsecutiveIdenticalActions) {
          return finish(ComputerUseAgentOutcome.repeatedAction,
              'REPEATED_ACTION');
        }

        onStage?.call('act', steps);
        try {
          final toolResult = await within(_session.execute(params));
          if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
          lastAction = decision.action;
          lastError = toolResult.success ? null :
              toolResult.error ?? 'TOOL_ERROR';
        } on TimeoutException {
          stop();
          return finish(ComputerUseAgentOutcome.timeout);
        } catch (_) {
          return finish(ComputerUseAgentOutcome.plannerError, 'TOOL_EXCEPTION');
        }
        steps++;
        if (lastError != null) continue;

        // Action success is not a verified goal. Observe the new state.
        onStage?.call('verify', steps);
        try {
          final updated = await within(_session.captureFrame());
          if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
          final checked = ComputerUseAgentObservation(
            goal: goal.trim(),
            framePng: updated,
            step: steps,
            lastAction: lastAction,
            lastError: null,
          );
          if (await within(_verifier.isSatisfied(checked))) {
            if (!authorized()) return finish(ComputerUseAgentOutcome.stopped);
            return finish(ComputerUseAgentOutcome.verified);
          }
        } on TimeoutException {
          stop();
          return finish(ComputerUseAgentOutcome.timeout);
        } catch (_) {
          lastError = 'VERIFICATION_ERROR';
        }
      }
      return finish(ComputerUseAgentOutcome.maxSteps, 'MAX_STEPS');
    } finally {
      timer.stop();
      _running = false;
    }
  }

  static const Set<String> _allowedActions = <String>{
    'observe',
    'open_app',
    'select_window',
    'select_window_at',
    'click',
    'type_text',
    'press_key',
  };

  static String _actionSignature(
    String action,
    Map<String, dynamic> params,
  ) {
    switch (action) {
      case 'click':
      case 'select_window_at':
        return '$action:${params['x']}:${params['y']}';
      case 'press_key':
        return 'press_key:${params['key']}';
      case 'open_app':
        return 'open_app:${params['app']}';
      case 'type_text':
        return 'type_text:<redacted>';
      default:
        return action;
    }
  }
}
