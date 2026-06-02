import 'chat_turn.dart';

class ChatTurnNormalizer {
  const ChatTurnNormalizer();

  static ChatRole roleFromText(
    String? value, {
    ChatRole fallbackRole = ChatRole.user,
  }) {
    switch (value?.trim().toLowerCase()) {
      case 'assistant':
        return ChatRole.assistant;
      case 'system':
        return ChatRole.system;
      case 'user':
        return ChatRole.user;
      default:
        return fallbackRole;
    }
  }

  ChatTurn normalize(ChatTurn turn) {
    return ChatTurn(
      role: turn.role,
      content: normalizeContent(
        turn.content,
        fallbackRole: turn.role,
      ),
    );
  }

  ChatTurn fromLegacyText(
    String value, {
    ChatRole? fallbackRole,
  }) {
    final parsed = _parse(value, fallbackRole: fallbackRole);
    return ChatTurn(
      role: parsed.role,
      content: parsed.content,
    );
  }

  String normalizeContent(
    String value, {
    ChatRole? fallbackRole,
  }) {
    return _parse(value, fallbackRole: fallbackRole).content;
  }

  _NormalizedTurn _parse(
    String value, {
    ChatRole? fallbackRole,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return _NormalizedTurn(
        role: fallbackRole ?? ChatRole.user,
        content: '',
      );
    }

    var remaining = trimmed;
    ChatRole? detectedRole;

    while (true) {
      final match = _matchLeadingRole(remaining);
      if (match == null) break;
      detectedRole ??= match.role;
      remaining = _stripLeadingSeparators(match.remaining);
    }

    final content = remaining.trim();
    return _NormalizedTurn(
      role: detectedRole ?? fallbackRole ?? ChatRole.user,
      content: content,
    );
  }

  _RoleMatch? _matchLeadingRole(String value) {
    final lower = value.toLowerCase();
    for (final entry in _roleTokens.entries) {
      if (!lower.startsWith(entry.key)) continue;
      final suffix = value.substring(entry.key.length);
      if (suffix.isNotEmpty &&
          !_startsWithSeparator(suffix) &&
          !_startsWithAnyRole(suffix)) {
        continue;
      }
      return _RoleMatch(
        role: entry.value,
        remaining: suffix,
      );
    }
    return null;
  }

  bool _startsWithSeparator(String value) {
    if (value.isEmpty) return true;
    final first = value[0];
    return first == ':' ||
        first == '-' ||
        first == '>' ||
        first == ' ' ||
        first == '\t' ||
        first == '\n' ||
        first == '\r';
  }

  bool _startsWithAnyRole(String value) {
    final lower = value.toLowerCase();
    return _roleTokens.keys.any(lower.startsWith);
  }

  String _stripLeadingSeparators(String value) {
    var index = 0;
    while (index < value.length && _isSeparatorCode(value.codeUnitAt(index))) {
      index++;
    }
    return value.substring(index);
  }

  bool _isSeparatorCode(int codeUnit) {
    return codeUnit == 58 || // :
        codeUnit == 45 || // -
        codeUnit == 62 || // >
        codeUnit == 32 || // space
        codeUnit == 9 || // tab
        codeUnit == 10 || // \n
        codeUnit == 13; // \r
  }

  static const Map<String, ChatRole> _roleTokens = <String, ChatRole>{
    'user': ChatRole.user,
    'assistant': ChatRole.assistant,
    'system': ChatRole.system,
  };
}

class _NormalizedTurn {
  const _NormalizedTurn({
    required this.role,
    required this.content,
  });

  final ChatRole role;
  final String content;
}

class _RoleMatch {
  const _RoleMatch({
    required this.role,
    required this.remaining,
  });

  final ChatRole role;
  final String remaining;
}
