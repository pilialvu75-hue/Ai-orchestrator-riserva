/// An envelope for every message exchanged between agents on the [MessageBus].
///
/// Messages are the sole communication primitive between agents.  All
/// inter-agent data — task requests, status updates, results, and errors —
/// must be wrapped in an [AgentMessage] so the bus can route and log them
/// uniformly.
class AgentMessage {
  AgentMessage({
    required this.id,
    required this.senderId,
    required this.type,
    this.recipientId,
    this.payload = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Unique message identifier (e.g. a UUID).
  final String id;

  /// Identifier of the agent that produced this message.
  final String senderId;

  /// Identifier of the target agent, or `null` for broadcast messages.
  final String? recipientId;

  /// Semantic type label (e.g. `'task_request'`, `'result'`, `'status'`).
  final String type;

  /// Arbitrary JSON-serialisable payload.
  final Map<String, dynamic> payload;

  /// Wall-clock time at which the message was created.
  final DateTime timestamp;

  /// Convenience: `true` when this is a broadcast message (no specific recipient).
  bool get isBroadcast => recipientId == null;

  @override
  String toString() =>
      'AgentMessage(id: $id, from: $senderId, to: ${recipientId ?? '*'}, '
      'type: $type)';
}
