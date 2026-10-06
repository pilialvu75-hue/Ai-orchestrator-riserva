import 'dart:convert';

import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Browser-local persistence for the visible Cantiere conversation.
///
/// This deliberately stores only user/assistant text. Provider credentials,
/// routing configuration and hidden runtime/system turns never enter browser
/// storage. shared_preferences_web maps this to the origin's local storage.
final class WorkshopWebConversationStorage {
  WorkshopWebConversationStorage._(this._preferences);

  static const String _storageKey = 'workshop.web.conversation.v1';
  static const int _maxTurns = 80;

  final SharedPreferences _preferences;

  static Future<WorkshopWebConversationStorage> open() async {
    final preferences = await SharedPreferences.getInstance();
    return WorkshopWebConversationStorage._(preferences);
  }

  Future<List<ChatTurn>> load() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return const <ChatTurn>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const <ChatTurn>[];
      }
      final turns = decoded['turns'];
      if (turns is! List<dynamic>) {
        return const <ChatTurn>[];
      }

      final restored = <ChatTurn>[];
      for (final item in turns) {
        if (item is! Map<String, dynamic>) continue;
        final roleName = item['role'];
        final content = item['content'];
        if (roleName is! String || content is! String) continue;

        final normalized = content.trim();
        if (normalized.isEmpty) continue;

        final role = switch (roleName) {
          'user' => ChatRole.user,
          'assistant' => ChatRole.assistant,
          _ => null,
        };
        if (role == null) continue;

        restored.add(ChatTurn(role: role, content: normalized));
      }

      if (restored.length <= _maxTurns) {
        return List<ChatTurn>.unmodifiable(restored);
      }
      return List<ChatTurn>.unmodifiable(
        restored.sublist(restored.length - _maxTurns),
      );
    } catch (_) {
      // Corrupted browser state must never prevent Aivexus from starting.
      return const <ChatTurn>[];
    }
  }

  Future<void> save(Iterable<ChatTurn> turns) async {
    final visible = turns
        .where((turn) =>
            turn.role == ChatRole.user || turn.role == ChatRole.assistant)
        .where((turn) => turn.content.trim().isNotEmpty)
        .toList(growable: false);

    final bounded = visible.length <= _maxTurns
        ? visible
        : visible.sublist(visible.length - _maxTurns);

    final payload = <String, Object?>{
      'version': 1,
      'turns': bounded
          .map(
            (turn) => <String, String>{
              'role': turn.role.name,
              'content': turn.content.trim(),
            },
          )
          .toList(growable: false),
    };

    await _preferences.setString(_storageKey, jsonEncode(payload));
  }

  Future<void> clear() => _preferences.remove(_storageKey);
}
