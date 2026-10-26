import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_service.dart';

/// Conservative, model-independent entry point for durable Assistant memories.
///
/// Only an explicit, single-line user instruction with a recognizable subject
/// and value may enter confirmed long-term memory. Ordinary chat, model output,
/// imported documents and web snippets never create confirmed memories here.
///
/// Keeping this deterministic avoids learning benchmark answers and hallucinated
/// facts as permanent user preferences. More ambitious candidate extraction
/// should use a separate, explicitly reviewed pipeline.
final class AssistantDurableMemoryCaptureService {
  AssistantDurableMemoryCaptureService({
    required AssistantDurableMemoryService memoryService,
    int Function()? now,
  })  : _memoryService = memoryService,
        _now = now ?? _clock;

  final AssistantDurableMemoryService _memoryService;
  final int Function() _now;

  static int _clock() => DateTime.now().millisecondsSinceEpoch;

  static final RegExp _save = RegExp(
    r'^(?:ricorda che|memorizza che|remember that)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _saveInConversation = RegExp(
    r'^(?:ricorda in questa chat che|ricorda solo in questa chat che)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _forget = RegExp(
    r'^(?:dimentica|forget)\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _assignment = RegExp(
    r'^(.{1,100}?)\s*(?:=|:|\s+è\s+|\s+vale\s+|\s+is\s+)\s*(.{1,400})$',
    caseSensitive: false,
  );
  static final RegExp _secrets = RegExp(
    r'\b(?:password|passphrase|api[\s_-]?key|access[\s_-]?token|'
    r'private[\s_-]?key|chiave privata|otp|pin segreto)\b',
    caseSensitive: false,
  );

  /// Returns whether this input actually changed a durable-memory record.
  ///
  /// No model-provided content or attachment text is processed. The caller is
  /// responsible for passing only the direct user's ordinary chat prompt.
  Future<bool> applyExplicitUserInstruction({
    required String sessionId,
    required String userPrompt,
  }) async {
    final input = userPrompt.trim();
    if (input.isEmpty ||
        input.length > 550 ||
        input.contains('\n') ||
        input.contains('\r') ||
        _secrets.hasMatch(input)) {
      return false;
    }

    var scope = AssistantMemoryScope.user;
    var scopeId = AssistantDurableMemoryContextService.localUserScopeId;
    final inChat = _saveInConversation.firstMatch(input);
    if (inChat != null) {
      if (sessionId.trim().isEmpty) return false;
      scope = AssistantMemoryScope.conversation;
      scopeId = sessionId.trim();
    }

    final save = inChat ?? _save.firstMatch(input);
    if (save != null) {
      final assignment = _parseAssignment(save.group(1)!);
      if (assignment == null) return false;
      await _memoryService.recordConfirmed(
        recordKey: assignment.key,
        scope: scope,
        scopeId: scopeId,
        kind: AssistantMemoryKind.fact,
        content: assignment.content,
        source: AssistantMemorySource.userExplicit,
        updatedAt: _now(),
      );
      return true;
    }

    final forget = _forget.firstMatch(input);
    if (forget != null) {
      final subject = forget.group(1)!.trim();
      final assignment = _parseAssignment(subject);
      final key = assignment?.key ?? _keyFromSubject(subject);
      if (key == null) return false;
      return _memoryService.remove(
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        recordKey: key,
      );
    }

    return false;
  }

  ({String key, String content})? _parseAssignment(String input) {
    final fact = input.trim().replaceFirst(RegExp(r'[.!]$'), '').trim();
    if (fact.contains('://') || fact.contains(String.fromCharCode(96))) {
      return null;
    }
    final match = _assignment.firstMatch(fact);
    if (match == null) return null;
    final subject = match.group(1)!.trim();
    final value = match.group(2)!.trim();
    if (value.isEmpty || _secrets.hasMatch(value)) return null;
    final key = _keyFromSubject(subject);
    if (key == null) return null;
    return (key: key, content: fact);
  }

  String? _keyFromSubject(String subject) {
    final normalized = subject
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9à-öø-ÿ]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (normalized.isEmpty || normalized.length > 100) return null;
    return 'explicit.$normalized';
  }
}
