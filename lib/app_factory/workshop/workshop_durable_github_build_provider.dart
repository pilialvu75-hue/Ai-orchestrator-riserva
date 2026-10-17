import 'dart:async';

import 'durable/workshop_durable_final_build_controller.dart';
import 'workshop_build_lab.dart';

typedef WorkshopDurableBuildAdvanceCall =
    Future<WorkshopDurableFinalBuildAdvance> Function(
  WorkshopBuildRequest request,
);

typedef WorkshopDurableBuildDelay = Future<void> Function(Duration duration);

/// BuildLab-compatible foreground driver for the persisted durable final build.
///
/// The polling loop here is deliberately NOT authoritative. Every iteration is
/// a one-shot call into [WorkshopDurableFinalBuildController], whose external
/// correlation/run/attempt state is already persisted before side effects.
/// Losing this Future or the whole app process therefore loses only foreground
/// observation: GitHub keeps running and a later `build()` call reconstructs
/// the same durable state instead of dispatching another workflow.
final class WorkshopDurableGitHubBuildProvider implements WorkshopBuildProvider {
  WorkshopDurableGitHubBuildProvider({
    required WorkshopDurableBuildAdvanceCall advance,
    required WorkshopBuildProvider toolchainDelegate,
    WorkshopDurableBuildDelay? delay,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 5),
  })  : _advance = advance,
        _toolchainDelegate = toolchainDelegate,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now {
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'must be greater than zero',
      );
    }
  }

  final WorkshopDurableBuildAdvanceCall _advance;
  final WorkshopBuildProvider _toolchainDelegate;
  final WorkshopDurableBuildDelay _delay;
  final DateTime Function() _now;
  final Duration pollInterval;
  final Set<String> _cancelled = <String>{};

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.remote;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) {
    return _toolchainDelegate.inspectToolchain(target);
  }

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    final startedAt = _now().toUtc();
    try {
      while (true) {
        if (_cancelled.contains(request.id)) {
          return _cancelledResult(request, startedAt);
        }

        final step = await _advance(request);
        if (step.isTerminal) {
          final result = step.buildResult ??
              _failure(
                request,
                startedAt,
                'Durable final build reached a terminal state without a result.',
                'durable_terminal_result_missing',
              );
          return _preserveRepairClassification(step, result);
        }

        if (_cancelled.contains(request.id)) {
          return _cancelledResult(request, startedAt);
        }
        await _delay(pollInterval);
      }
    } catch (error) {
      return _failure(
        request,
        startedAt,
        _boundedError(error),
        'durable_final_build_driver_failed',
      );
    } finally {
      _cancelled.remove(request.id);
    }
  }

  /// Cancellation stops only this foreground observer.
  ///
  /// The persisted durable external operation intentionally remains intact:
  /// GitHub may already be running and blindly trying to roll it back would
  /// reintroduce the ambiguous-side-effect problem this path removes. A later
  /// explicit retry/reopen can reconcile that exact run.
  @override
  Future<void> cancel(String requestId) async {
    final normalized = requestId.trim();
    if (normalized.isNotEmpty) _cancelled.add(normalized);
  }

  /// Preserve the historical automatic-repair contract for a workflow that
  /// actually completed with a generated-project build error.
  ///
  /// The durable coordinator intentionally stores only the provider-neutral
  /// failure class in its event envelope. Until failed-step/log observation is
  /// added to the durable gateway, map `buildError` to the broad historical
  /// `remote_project_build_failed` code so Cantiere may enter its bounded
  /// Reviewer-gated repair loop instead of misclassifying project code as
  /// infrastructure failure.
  WorkshopBuildResult _preserveRepairClassification(
    WorkshopDurableFinalBuildAdvance step,
    WorkshopBuildResult result,
  ) {
    if (result.status != WorkshopBuildStatus.failed ||
        result.errors.contains('remote_project_build_failed')) {
      return result;
    }

    var remoteProjectBuildFailed = false;
    for (final event in step.snapshot.events.reversed) {
      if (event.type != 'ci.completed' || event.success) continue;
      remoteProjectBuildFailed = event.failureClass?.name == 'buildError';
      break;
    }
    if (!remoteProjectBuildFailed) return result;

    return WorkshopBuildResult(
      requestId: result.requestId,
      target: result.target,
      status: result.status,
      startedAt: result.startedAt,
      finishedAt: result.finishedAt,
      artifactPath: result.artifactPath,
      message: result.message,
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      testsPassed: result.testsPassed,
      analysisPassed: result.analysisPassed,
      formatPassed: result.formatPassed,
      warnings: result.warnings,
      errors: const <String>['remote_project_build_failed'],
    );
  }

  WorkshopBuildResult _cancelledResult(
    WorkshopBuildRequest request,
    DateTime startedAt,
  ) {
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.cancelled,
      startedAt: startedAt,
      finishedAt: _now().toUtc(),
      message:
          'Foreground durable build observation was cancelled; remote state remains recoverable.',
    );
  }

  WorkshopBuildResult _failure(
    WorkshopBuildRequest request,
    DateTime startedAt,
    String message,
    String code,
  ) {
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: startedAt,
      finishedAt: _now().toUtc(),
      message: message,
      errors: <String>[code],
    );
  }

  static String _boundedError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return text.length <= 500 ? text : '${text.substring(0, 500)}…';
  }
}
