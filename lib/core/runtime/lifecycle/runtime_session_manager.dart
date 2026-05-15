import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Represents one active inference session.
class InferenceSession {
  InferenceSession._({
    required this.sessionId,
    required this.modelPath,
    required this.prompt,
    required this.cancellationToken,
    required this.startedAt,
  });

  static const _uuid = Uuid();

  /// Creates a new [InferenceSession] for [modelPath] with [prompt].
  ///
  /// Session IDs are generated with UUIDs (v4) to guarantee uniqueness even
  /// when multiple sessions are created within the same microsecond.
  factory InferenceSession.create({
    required String modelPath,
    required String prompt,
  }) {
    return InferenceSession._(
      sessionId: _uuid.v4(),
      modelPath: modelPath,
      prompt: prompt,
      cancellationToken: CancellationToken(),
      startedAt: DateTime.now(),
    );
  }

  /// Unique identifier for this session (UUID v4).
  final String sessionId;

  /// Absolute path to the model file used by this session.
  final String modelPath;

  /// The prompt submitted for this session.
  final String prompt;

  /// Token that can be used to request cancellation of the inference.
  final CancellationToken cancellationToken;

  /// Wall-clock time when the session was created.
  final DateTime startedAt;

  @override
  String toString() =>
      'InferenceSession(id=$sessionId, model=$modelPath, '
      'startedAt=$startedAt)';
}

// ---------------------------------------------------------------------------
// Manager
// ---------------------------------------------------------------------------

/// Manages at most **one** active [InferenceSession] at a time.
///
/// Starting a new session automatically cancels and replaces any existing
/// one.  All session lifecycle events are broadcast on [sessionStream] so
/// that interested widgets or services can react without polling.
class RuntimeSessionManager {
  RuntimeSessionManager();

  InferenceSession? _activeSession;

  final StreamController<InferenceSession?> _controller =
      StreamController<InferenceSession?>.broadcast();

  /// The currently active session, or `null` when idle.
  InferenceSession? get activeSession => _activeSession;

  /// Emits the new [InferenceSession] whenever one starts, and `null`
  /// whenever a session ends or is cancelled.
  Stream<InferenceSession?> get sessionStream => _controller.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Cancels any existing session, then creates and returns a new one.
  InferenceSession beginSession({
    required String modelPath,
    required String prompt,
  }) {
    // Cancel any existing session before creating a new one.
    if (_activeSession != null) {
      cancelSession(_activeSession!.sessionId);
    }

    final session = InferenceSession.create(
      modelPath: modelPath,
      prompt: prompt,
    );

    _activeSession = session;
    _emit(session);

    debugPrint(
      '[SESSION_START] id=${session.sessionId} '
      'model=$modelPath',
    );
    return session;
  }

  /// Ends the session identified by [sessionId] without cancellation.
  ///
  /// Safe to call even if [sessionId] does not match the active session
  /// (the call is a no-op in that case).
  void endSession(String sessionId) {
    if (_activeSession?.sessionId != sessionId) return;

    debugPrint('[SESSION_END] id=$sessionId');
    _activeSession = null;
    _emit(null);
  }

  /// Requests cancellation of the session identified by [sessionId] and
  /// removes it from the active slot.
  void cancelSession(String sessionId) {
    if (_activeSession?.sessionId != sessionId) return;

    debugPrint('[SESSION_CANCEL] id=$sessionId');
    _activeSession!.cancellationToken.cancel();
    _activeSession = null;
    _emit(null);
  }

  /// Cancels the active session (if any).
  void cancelAll() {
    if (_activeSession != null) {
      cancelSession(_activeSession!.sessionId);
    }
  }

  /// Closes the broadcast stream.  Call when the manager is being torn down.
  void dispose() {
    cancelAll();
    _controller.close();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _emit(InferenceSession? session) {
    if (!_controller.isClosed) {
      _controller.add(session);
    }
  }
}
