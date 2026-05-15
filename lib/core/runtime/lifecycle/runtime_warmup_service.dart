import 'dart:async';

import 'package:flutter/foundation.dart';

/// Interface for executing a minimal inference dry-run.
///
/// On Android the concrete implementation wraps the FFI bridge.
/// Keeping it behind this interface allows the [RuntimeWarmupService] to be
/// tested without a real native library and makes the non-Android skip path
/// explicit.
abstract interface class WarmupInferenceExecutor {
  /// Runs a single minimal inference with [modelPath] and returns `true` when
  /// at least one token is produced within the timeout.
  Future<bool> runMinimalInference(String modelPath);
}

/// Executes a minimal "dry-run" inference to confirm the runtime is
/// operational before the state machine advances to `ready`.
///
/// The warmup sends the fixed prompt `"Hi"` and expects at least one token
/// back within 30 seconds.  It intentionally has no side-effects on the
/// [RuntimeStateMachine] — the boot manager is responsible for state
/// transitions.
class RuntimeWarmupService {
  /// [executor] is optional.  When `null` the warmup step is skipped, which
  /// is the correct behaviour on desktop and macOS builds where `llama-cli`
  /// handles inference directly and no FFI bridge is loaded.
  const RuntimeWarmupService({this.executor});

  final WarmupInferenceExecutor? executor;

  static const Duration _warmupTimeout = Duration(seconds: 30);
  static const String _warmupPrompt = 'Hi';

  /// Runs the warmup dry-run for [modelPath].
  ///
  /// Returns `true` when:
  /// - [executor] is `null` (warmup skipped on non-Android builds), or
  /// - the executor produces at least one token within [_warmupTimeout].
  ///
  /// Returns `false` when the executor reports failure or times out.
  Future<bool> runWarmup(String modelPath) async {
    if (executor == null) {
      debugPrint(
        '[RUNTIME_READY] Warmup skipped – no executor (non-Android build)',
      );
      return true;
    }

    debugPrint(
      '[RUNTIME_READY] Warmup starting: model=$modelPath '
      'prompt="$_warmupPrompt" timeout=${_warmupTimeout.inSeconds}s',
    );

    try {
      final result = await executor!
          .runMinimalInference(modelPath)
          .timeout(_warmupTimeout);

      if (result) {
        debugPrint('[RUNTIME_READY] Warmup OK – at least one token produced');
      } else {
        debugPrint('[RUNTIME_READY] Warmup FAIL – executor returned false');
      }
      return result;
    } on TimeoutException {
      debugPrint(
        '[RUNTIME_READY] Warmup FAIL – timed out after '
        '${_warmupTimeout.inSeconds}s',
      );
      return false;
    } catch (e) {
      debugPrint('[RUNTIME_READY] Warmup FAIL – exception: $e');
      return false;
    }
  }
}
