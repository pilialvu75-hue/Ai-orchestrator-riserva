import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// A PASS requires an accessibility match for the synthetic marker.
/// An app launching or a screenshot alone never counts as PASS.
final class ComputerUseSmokeResult {
  const ComputerUseSmokeResult({
    required this.passed,
    required this.stage,
    required this.code,
  });

  final bool passed;
  final String stage;
  final String code;
}

/// A bounded, deterministic, user-authorized test, not an LLM agent.
final class ComputerUseSmokeScenario {
  ComputerUseSmokeScenario({
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  })  : _clock = clock ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  Future<ComputerUseSmokeResult> run({
    required ComputerUseSession session,
    void Function(String stage)? onStage,
  }) async {
    if (!session.canInteract) {
      return const ComputerUseSmokeResult(
        passed: false,
        stage: 'authorization',
        code: 'READ_ONLY_SESSION',
      );
    }

    final marker = 'AIVEXUS-CU-QA-${_clock().microsecondsSinceEpoch}';
    if (!RegExp(r'^AIVEXUS-CU-QA-[0-9]{8,20}$').hasMatch(marker)) {
      return const ComputerUseSmokeResult(
        passed: false,
        stage: 'marker',
        code: 'INVALID_TEST_MARKER',
      );
    }

    Future<ComputerUseSmokeResult?> perform(
      String stage,
      Map<String, dynamic> params,
    ) async {
      if (!session.canInteract) {
        return ComputerUseSmokeResult(
          passed: false,
          stage: stage,
          code: 'SESSION_INACTIVE',
        );
      }
      onStage?.call(stage);
      final ToolResult result = await session.execute(params);
      if (!result.success) {
        return ComputerUseSmokeResult(
          passed: false,
          stage: stage,
          code: result.error ?? 'UNKNOWN_ERROR',
        );
      }
      return null;
    }

    // The executable is fixed by the host, never chosen by model text.
    var failed = await perform('open', <String, dynamic>{
      'action': 'open_app',
      'app': 'notepad',
    });
    if (failed != null) return failed;

    onStage?.call('waiting');
    await _delay(const Duration(milliseconds: 1800));
    if (!session.canInteract) {
      return const ComputerUseSmokeResult(
        passed: false,
        stage: 'waiting',
        code: 'SESSION_INACTIVE',
      );
    }

    failed = await perform('select', <String, dynamic>{
      'action': 'select_window',
    });
    if (failed != null) return failed;

    // Only a generated synthetic marker: no private user data.
    failed = await perform('type', <String, dynamic>{
      'action': 'type_text',
      'text': marker,
    });
    if (failed != null) return failed;

    failed = await perform('verify', <String, dynamic>{
      'action': 'verify_test_marker',
      'marker': marker,
    });
    if (failed != null) return failed;

    failed = await perform('observe', <String, dynamic>{
      'action': 'observe',
    });
    if (failed != null) return failed;

    onStage?.call('complete');
    return const ComputerUseSmokeResult(
      passed: true,
      stage: 'complete',
      code: 'VERIFIED',
    );
  }
}
