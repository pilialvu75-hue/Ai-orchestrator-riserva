/// Lifecycle states for all [BaseAgent] instances.
///
/// Transitions follow a strict state machine:
///
/// ```
/// created → initialising → idle ⇄ active ⇄ suspended → shutdown
///                                                      ↑
///                                              (error → idle or shutdown)
/// ```
enum AgentLifecycleState {
  /// Agent has been created but [BaseAgent.initialize] has not been called yet.
  created,

  /// [BaseAgent.initialize] is in progress.
  initialising,

  /// Agent is initialised and ready to accept tasks.
  idle,

  /// Agent is currently executing a task (see [BaseAgent.executeTask]).
  active,

  /// Agent has been temporarily paused via [BaseAgent.suspend].
  ///
  /// No new tasks are accepted. Resume by calling [BaseAgent.activate].
  suspended,

  /// Agent encountered an unrecoverable error and is awaiting reset.
  error,

  /// [BaseAgent.shutdown] has completed; the agent can no longer be used.
  shutdown,
}

/// Snapshot of an agent's current lifecycle state emitted on state changes.
class AgentLifecycleEvent {
  const AgentLifecycleEvent({
    required this.agentId,
    required this.previous,
    required this.current,
    this.message,
  });

  /// Identifier of the agent that changed state.
  final String agentId;

  /// State before the transition.
  final AgentLifecycleState previous;

  /// State after the transition.
  final AgentLifecycleState current;

  /// Optional human-readable description of why the transition occurred.
  final String? message;

  @override
  String toString() =>
      'AgentLifecycleEvent($agentId: $previous → $current'
      '${message != null ? ', $message' : ''})';
}
