enum ChatRole {
  user,
  assistant,
  system,
}

class ChatTurn {
  final ChatRole role;
  final String content;

  /// Se true, questo turno viene mostrato in UI ma NON viene incluso
  /// nel contesto passato al modello nei turni successivi.
  /// Usato per risposte di sistema (webSearch, command, ecc.) che
  /// non devono influenzare il ragionamento del modello.
  final bool excludeFromContext;

  const ChatTurn({
    required this.role,
    required this.content,
    this.excludeFromContext = false,
  });

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
