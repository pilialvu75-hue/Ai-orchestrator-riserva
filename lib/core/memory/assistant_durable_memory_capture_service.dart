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

  // A single serialized queue ensures two rapid updates never overwrite each
  // other through concurrent SQLite read-modify-write operations.
  Future<void> _pendingWrites = Future<void>.value();
  bool _resetInProgress = false;

  /// Prevents in-flight memory capture from repopulating storage after reset.
  /// Used by the Danger Zone coordinator together with the semantic index
  /// barrier. New captures are discarded while reset is in progress.
  Future<T> runWithResetBarrier<T>(Future<T> Function() operation) async {
    if (_resetInProgress) {
      throw StateError('Durable memory reset is already in progress.');
    }
    _resetInProgress = true;
    try {
      await _pendingWrites;
      return await operation();
    } finally {
      _resetInProgress = false;
    }
  }

  static int _clock() => DateTime.now().millisecondsSinceEpoch;

  // Direct requests such as "Ricorda il budget è 732" are explicit too.
  // The assignment parser below still requires a subject and a value;
  // ordinary conversational statements cannot silently become memories.
  static final RegExp _save = RegExp(
    r'^(?:ricorda(?: che)?|memorizza(?: che)?|remember that)\s+(.+)
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
  }) {
    if (_resetInProgress) return Future<bool>.value(false);

    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _applyExplicitUserInstruction(
        sessionId: sessionId,
        userPrompt: userPrompt,
      );
    });
    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  // A deliberately closed vocabulary for a future opt-in review surface.
  // No model output, imported content or arbitrary personal details.
  static final RegExp _answerPreference = RegExp(
    r'^preferisco (?:le )?risposte '
    r'(brevi|dettagliate|in italiano|in francese|in inglese|in spagnolo)[.!]?$',
    caseSensitive: false,
  );

  /// Stage a small user-stated preference as a *candidate*, never confirmed.
  ///
  /// Disabled by default. A future user-facing consent/review flow may call
  /// this for direct, attachment-free ordinary user prompts; it must not
  /// pass model output, documents or a system/worker prompt.
  Future<bool> proposeUserPreferenceCandidate({
    required String userPrompt,
    bool consentEnabled = false,
  }) {
    if (!consentEnabled || _resetInProgress) {
      return Future<bool>.value(false);
    }

    final operation = _pendingWrites.then((_) async {
      if (_resetInProgress) return false;
      final input = userPrompt.trim();
      if (input.length > 110 ||
          input.contains('\n') ||
          input.contains('\r') ||
          _secrets.hasMatch(input)) {
        return false;
      }
      final match = _answerPreference.firstMatch(input);
      if (match == null) return false;

      final preference = match.group(1)!.toLowerCase();
      final language = preference.startsWith('in ');
      await _memoryService.recordUserCandidate(
        recordKey: language
            ? 'suggestion.answer_language'
            : 'suggestion.answer_length',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.preference,
        content: input.replaceFirst(RegExp(r'[.!]$'), ''),
        updatedAt: _now(),
      );
      return true;
    });

    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Only display *reviewable* local-user preferences, not model candidates.
  /// This does not connect a UI or enable automatic collection.
  Future<List<AssistantDurableMemoryRecord>>
      loadReviewablePreferenceCandidates() async {
    final pending = await _memoryService.loadCandidates(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      limit: AssistantDurableMemoryPolicy.maxRecordsPerScope,
    );
    return List<AssistantDurableMemoryRecord>.unmodifiable(
      pending.where((item) =>
          item.source == AssistantMemorySource.userStatement &&
          item.kind == AssistantMemoryKind.preference &&
          _validPreferenceForKey(item.content, item.recordKey)),
    );
  }

  /// Called only after the owner actively chooses approve/edit/reject in a
  /// future review screen. No silent self-promotion is permitted.
  ///
  /// The reset barrier also covers this queue, preventing approvals from
  /// resurrecting data during Danger Zone reset.
  Future<bool> reviewUserPreferenceCandidate({
    required AssistantDurableMemoryRecord reviewed,
    required bool approve,
    bool userConfirmed = false,
    String? correctedContent,
  }) {
    if (!userConfirmed || _resetInProgress ||
        reviewed.scope != AssistantMemoryScope.user ||
        reviewed.scopeId !=
            AssistantDurableMemoryContextService.localUserScopeId ||
        reviewed.status != AssistantMemoryStatus.candidate ||
        reviewed.source != AssistantMemorySource.userStatement ||
        reviewed.kind != AssistantMemoryKind.preference ||
        !_validPreferenceForKey(reviewed.content, reviewed.recordKey)) {
      return Future<bool>.value(false);
    }

    final finalText = (correctedContent ?? reviewed.content).trim();
    if (approve && !_validPreferenceForKey(
        finalText, reviewed.recordKey)) {
      return Future<bool>.value(false);
    }
    if (!approve && correctedContent != null) {
      return Future<bool>.value(false);
    }

    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _memoryService.resolveUserStatementCandidate(
        reviewed: reviewed,
        approve: approve,
        approvedContent: approve ? finalText : null,
        reviewedAt: _now(),
      );
    });

    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  bool _validPreferenceForKey(String input, String recordKey) {
    final normalized = input.trim();
    if (normalized.isEmpty ||
        normalized.length > 110 ||
        normalized.contains('\n') ||
        normalized.contains('\r') ||
        _secrets.hasMatch(normalized)) {
      return false;
    }
    final match = _answerPreference.firstMatch(normalized);
    if (match == null) return false;
    final language = match.group(1)!.toLowerCase().startsWith('in ');
    return recordKey == (language
        ? 'suggestion.answer_language'
        : 'suggestion.answer_length');
  }

  /// Developer review of confirmed local-user facts; never other scopes.
  Future<List<AssistantDurableMemoryRecord>>
      loadReviewableConfirmedUserMemory() {
    return _memoryService.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      limit: AssistantDurableMemoryPolicy.maxRecordsPerScope,
    );
  }

  /// Never erase a newer correction using an older displayed record.
  /// Every deletion requires an explicit per-action user confirmation.
  Future<bool> forgetReviewedConfirmedUserMemory({
    required AssistantDurableMemoryRecord reviewed,
    bool userConfirmed = false,
  }) {
    if (!userConfirmed ||
        _resetInProgress ||
        reviewed.scope != AssistantMemoryScope.user ||
        reviewed.scopeId !=
            AssistantDurableMemoryContextService.localUserScopeId ||
        reviewed.status != AssistantMemoryStatus.confirmed) {
      return Future<bool>.value(false);
    }
    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _memoryService.removeReviewedConfirmedUserMemory(
        reviewed: reviewed,
      );
    });
    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<bool> _applyExplicitUserInstruction({
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
    if (fact.endsWith('?') ||
        fact.contains('://') ||
        fact.contains(String.fromCharCode(96))) {
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
,
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
  }) {
    if (_resetInProgress) return Future<bool>.value(false);

    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _applyExplicitUserInstruction(
        sessionId: sessionId,
        userPrompt: userPrompt,
      );
    });
    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  // A deliberately closed vocabulary for a future opt-in review surface.
  // No model output, imported content or arbitrary personal details.
  static final RegExp _answerPreference = RegExp(
    r'^preferisco (?:le )?risposte '
    r'(brevi|dettagliate|in italiano|in francese|in inglese|in spagnolo)[.!]?$',
    caseSensitive: false,
  );

  /// Stage a small user-stated preference as a *candidate*, never confirmed.
  ///
  /// Disabled by default. A future user-facing consent/review flow may call
  /// this for direct, attachment-free ordinary user prompts; it must not
  /// pass model output, documents or a system/worker prompt.
  Future<bool> proposeUserPreferenceCandidate({
    required String userPrompt,
    bool consentEnabled = false,
  }) {
    if (!consentEnabled || _resetInProgress) {
      return Future<bool>.value(false);
    }

    final operation = _pendingWrites.then((_) async {
      if (_resetInProgress) return false;
      final input = userPrompt.trim();
      if (input.length > 110 ||
          input.contains('\n') ||
          input.contains('\r') ||
          _secrets.hasMatch(input)) {
        return false;
      }
      final match = _answerPreference.firstMatch(input);
      if (match == null) return false;

      final preference = match.group(1)!.toLowerCase();
      final language = preference.startsWith('in ');
      await _memoryService.recordUserCandidate(
        recordKey: language
            ? 'suggestion.answer_language'
            : 'suggestion.answer_length',
        scope: AssistantMemoryScope.user,
        scopeId: AssistantDurableMemoryContextService.localUserScopeId,
        kind: AssistantMemoryKind.preference,
        content: input.replaceFirst(RegExp(r'[.!]$'), ''),
        updatedAt: _now(),
      );
      return true;
    });

    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Only display *reviewable* local-user preferences, not model candidates.
  /// This does not connect a UI or enable automatic collection.
  Future<List<AssistantDurableMemoryRecord>>
      loadReviewablePreferenceCandidates() async {
    final pending = await _memoryService.loadCandidates(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      limit: AssistantDurableMemoryPolicy.maxRecordsPerScope,
    );
    return List<AssistantDurableMemoryRecord>.unmodifiable(
      pending.where((item) =>
          item.source == AssistantMemorySource.userStatement &&
          item.kind == AssistantMemoryKind.preference &&
          _validPreferenceForKey(item.content, item.recordKey)),
    );
  }

  /// Called only after the owner actively chooses approve/edit/reject in a
  /// future review screen. No silent self-promotion is permitted.
  ///
  /// The reset barrier also covers this queue, preventing approvals from
  /// resurrecting data during Danger Zone reset.
  Future<bool> reviewUserPreferenceCandidate({
    required AssistantDurableMemoryRecord reviewed,
    required bool approve,
    bool userConfirmed = false,
    String? correctedContent,
  }) {
    if (!userConfirmed || _resetInProgress ||
        reviewed.scope != AssistantMemoryScope.user ||
        reviewed.scopeId !=
            AssistantDurableMemoryContextService.localUserScopeId ||
        reviewed.status != AssistantMemoryStatus.candidate ||
        reviewed.source != AssistantMemorySource.userStatement ||
        reviewed.kind != AssistantMemoryKind.preference ||
        !_validPreferenceForKey(reviewed.content, reviewed.recordKey)) {
      return Future<bool>.value(false);
    }

    final finalText = (correctedContent ?? reviewed.content).trim();
    if (approve && !_validPreferenceForKey(
        finalText, reviewed.recordKey)) {
      return Future<bool>.value(false);
    }
    if (!approve && correctedContent != null) {
      return Future<bool>.value(false);
    }

    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _memoryService.resolveUserStatementCandidate(
        reviewed: reviewed,
        approve: approve,
        approvedContent: approve ? finalText : null,
        reviewedAt: _now(),
      );
    });

    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  bool _validPreferenceForKey(String input, String recordKey) {
    final normalized = input.trim();
    if (normalized.isEmpty ||
        normalized.length > 110 ||
        normalized.contains('\n') ||
        normalized.contains('\r') ||
        _secrets.hasMatch(normalized)) {
      return false;
    }
    final match = _answerPreference.firstMatch(normalized);
    if (match == null) return false;
    final language = match.group(1)!.toLowerCase().startsWith('in ');
    return recordKey == (language
        ? 'suggestion.answer_language'
        : 'suggestion.answer_length');
  }

  /// Developer review of confirmed local-user facts; never other scopes.
  Future<List<AssistantDurableMemoryRecord>>
      loadReviewableConfirmedUserMemory() {
    return _memoryService.loadConfirmed(
      scope: AssistantMemoryScope.user,
      scopeId: AssistantDurableMemoryContextService.localUserScopeId,
      limit: AssistantDurableMemoryPolicy.maxRecordsPerScope,
    );
  }

  /// Never erase a newer correction using an older displayed record.
  /// Every deletion requires an explicit per-action user confirmation.
  Future<bool> forgetReviewedConfirmedUserMemory({
    required AssistantDurableMemoryRecord reviewed,
    bool userConfirmed = false,
  }) {
    if (!userConfirmed ||
        _resetInProgress ||
        reviewed.scope != AssistantMemoryScope.user ||
        reviewed.scopeId !=
            AssistantDurableMemoryContextService.localUserScopeId ||
        reviewed.status != AssistantMemoryStatus.confirmed) {
      return Future<bool>.value(false);
    }
    final operation = _pendingWrites.then((_) {
      if (_resetInProgress) return Future<bool>.value(false);
      return _memoryService.removeReviewedConfirmedUserMemory(
        reviewed: reviewed,
      );
    });
    _pendingWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<bool> _applyExplicitUserInstruction({
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
    if (fact.endsWith('?') ||
        fact.contains('://') ||
        fact.contains(String.fromCharCode(96))) {
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
