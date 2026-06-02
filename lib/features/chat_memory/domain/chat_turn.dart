enum ChatRole {
  user,
  assistant,
  system,
}

class ChatTurn {
  final ChatRole role;
  final String content;

  const ChatTurn({
    required this.role,
    required this.content,
  });

  ChatTurn copyWith({
    ChatRole? role,
    String? content,
  }) {
    return ChatTurn(
      role: role ?? this.role,
      content: content ?? this.content,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChatTurn &&
        other.role == role &&
        other.content == content;
  }

  @override
  int get hashCode => Object.hash(role, content);
}
