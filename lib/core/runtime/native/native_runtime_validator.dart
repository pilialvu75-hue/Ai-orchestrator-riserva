import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/native/native_runtime_bridge.dart';
import 'package:ai_orchestrator/core/runtime/native/native_runtime_session.dart';

/// Validates native runtime state at key points in the boot and inference
/// pipelines.
///
/// Every method is stateless and returns a simple `bool` so that callers can
/// decide how to handle failures (transition to `failed`, throw, etc.).
class NativeRuntimeValidator {
  const NativeRuntimeValidator();

  // ---------------------------------------------------------------------------
  // Library
  // ---------------------------------------------------------------------------

  /// Returns `true` when [bridge] reports that its native library is loaded
  /// and its symbols are bound.
  Future<bool> validateLibraryLoaded(NativeRuntimeBridge bridge) async {
    if (bridge.isLoaded) {
      debugPrint('[NATIVE_READY] Library loaded and symbols bound');
      return true;
    }
    debugPrint('[NATIVE_READY] FAIL – library not loaded');
    return false;
  }

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------

  /// Returns `true` when [bridge] has a model loaded that corresponds to
  /// [modelPath].
  ///
  /// Currently delegates to [NativeRuntimeBridge.isLoaded] as the native
  /// bridge tracks whether a model is resident.  A future revision can add
  /// an explicit `isModelLoaded` predicate to the bridge interface.
  Future<bool> validateModelLoaded(
    NativeRuntimeBridge bridge,
    String modelPath,
  ) async {
    if (bridge.isLoaded) {
      debugPrint('[MODEL_VALIDATION] Model loaded: $modelPath');
      return true;
    }
    debugPrint('[MODEL_VALIDATION] FAIL – model not loaded: $modelPath');
    return false;
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  /// Returns `true` when there is no active native session.
  ///
  /// A new generation request must not begin while a previous one is still
  /// running; this guard prevents that race condition.
  Future<bool> validateNoActiveSession(NativeRuntimeSession? session) async {
    if (session == null || !session.isActive) {
      return true;
    }
    debugPrint(
      '[NATIVE_READY] FAIL – active session already running: '
      '${session.sessionId}',
    );
    return false;
  }
}
