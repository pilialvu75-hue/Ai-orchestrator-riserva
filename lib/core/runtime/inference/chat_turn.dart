/// Canonical conversation turn contract shared by runtime, Assistant, Cloud
/// and Workshop boundaries.
///
/// This type belongs to core because [InferenceRequest] and runtime providers
/// consume it directly. Feature layers may re-export it for compatibility,
/// but core must not depend on a feature-owned conversation type.
enum ChatRole {
  user,
  assistant,
  system,
}

class ChatTurn {
  const ChatTurn({
    required this.role,
    required this.content,
    this.excludeFromContext = false,
  });

  final ChatRole role;
  final String content;

  /// When true the turn may remain visible to the UI but must not be included
  /// in model context on subsequent requests.
  final bool excludeFromContext;

  ChatTurn copyWith({
    ChatRole? role,
    String? content,
    bool? excludeFromContext,
  }) {
    return ChatTurn(
      role: role ?? this.role,
      content: content ?? this.content,
      excludeFromContext: excludeFromContext ?? this.excludeFromContext,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChatTurn &&
        other.role == role &&
        other.content == content &&
        other.excludeFromContext == excludeFromContext;
  }

  @override
  int get hashCode => Object.hash(role, content, excludeFromContext);
}
