import 'package:ai_orchestrator/core/agents/agent_message.dart';
import 'package:ai_orchestrator/core/agents/agent_lifecycle.dart';

/// Abstract contract for the agent message bus.
///
/// The [MessageBus] is the central nervous system of the multi-agent runtime.
/// Every agent publishes and subscribes through this single interface, keeping
/// agents decoupled from one another.
///
/// Dependency rule:
///   core/agents/ defines [MessageBus]
///   features/ / native/ provide concrete implementations
///
/// Planned implementations:
/// - `InProcessMessageBus` — synchronous in-memory bus for single-device runs.
/// - `IsolateMessageBus` — `SendPort`/`ReceivePort` bridge for Dart Isolates.
/// - `RemoteMessageBus` — WebSocket / gRPC bridge for cloud-distributed agents.
abstract class MessageBus {
  /// Publishes [message] to the bus.
  ///
  /// If [message.recipientId] is set, only that agent receives it.
  /// Otherwise, all subscribed agents receive it (broadcast).
  Future<void> publish(AgentMessage message);

  /// Registers [handler] to receive messages addressed to [agentId].
  ///
  /// Returns a subscription token that can be passed to [unsubscribe].
  String subscribe(
    String agentId,
    void Function(AgentMessage message) handler,
  );

  /// Cancels the subscription identified by [subscriptionToken].
  void unsubscribe(String subscriptionToken);

  /// Stream of [AgentLifecycleEvent]s emitted whenever any registered agent
  /// changes lifecycle state.
  ///
  /// Consumers (e.g. a monitoring dashboard) listen here instead of polling
  /// individual agents.
  Stream<AgentLifecycleEvent> get lifecycleEvents;

  /// Broadcasts a lifecycle state change on behalf of an agent.
  ///
  /// Called internally by [BaseAgent] during state transitions.
  void notifyLifecycle(AgentLifecycleEvent event);

  /// Releases all subscriptions and closes internal streams.
  Future<void> dispose();

  // TODO(future): add reply(AgentMessage original, AgentMessage reply) helper.
  // TODO(future): add request-response pattern with timeout.
}
