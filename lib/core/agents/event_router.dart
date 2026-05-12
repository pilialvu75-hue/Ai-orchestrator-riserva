import 'package:ai_orchestrator/core/agents/agent_message.dart';

/// A typed event emitted by an agent or the runtime into the event system.
class AgentEvent {
  AgentEvent({
    required this.id,
    required this.sourceId,
    required this.eventType,
    this.payload = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Unique event identifier.
  final String id;

  /// Identifier of the component (agent or runtime) that emitted the event.
  final String sourceId;

  /// Semantic event type label (e.g. `'task_started'`, `'tool_called'`,
  /// `'context_updated'`).
  final String eventType;

  /// Arbitrary JSON-serialisable payload.
  final Map<String, dynamic> payload;

  /// Wall-clock time at which the event was emitted.
  final DateTime timestamp;

  @override
  String toString() =>
      'AgentEvent(id: $id, source: $sourceId, type: $eventType)';
}

/// Subscription handle returned by [EventRouter.on].
///
/// Call [cancel] to stop receiving events without disposing the whole router.
abstract class EventSubscription {
  /// Cancels this subscription.
  void cancel();
}

/// Abstract contract for the agent event routing system.
///
/// [EventRouter] is a pub/sub backbone that decouples event producers from
/// consumers.  Agents, tools, and runtime components emit events; dashboards,
/// loggers, and other agents subscribe to the types they care about.
///
/// Dependency rule:
///   core/agents/ defines [EventRouter]
///   features/ / plugins/ provide concrete implementations
///
/// Planned implementations:
/// - `InProcessEventRouter` — synchronous Dart `StreamController`-based router.
/// - `PersistentEventRouter` — writes events to SQLite for audit/replay.
abstract class EventRouter {
  /// Emits [event] to all matching subscribers.
  void emit(AgentEvent event);

  /// Subscribes [handler] to all events whose [AgentEvent.eventType] matches
  /// [eventType].
  ///
  /// Pass `'*'` to receive all events regardless of type.
  EventSubscription on(
    String eventType,
    void Function(AgentEvent event) handler,
  );

  /// Converts an [AgentEvent] to an [AgentMessage] and publishes it for
  /// cross-agent delivery.
  ///
  /// Useful when an event must also trigger a direct agent-to-agent message.
  AgentMessage toMessage(AgentEvent event, {String? recipientId});

  /// Replays the [count] most recent events of [eventType] to [handler].
  ///
  /// Used by late-joining agents to catch up on missed events.
  ///
  /// Returns immediately when no history is available.
  void replay(
    String eventType,
    void Function(AgentEvent event) handler, {
    int count = 10,
  });

  /// Closes all subscriptions and releases internal resources.
  Future<void> dispose();

  // TODO(future): add filter() for pattern-matched event subscriptions.
  // TODO(future): add persistence adapter for event sourcing.
}
