import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

const String _completeSystemPrompt =
    'You are a helpful assistant. Give complete answers when appropriate.';

// Istruzione globale per l'abilitazione della ricerca web
const String _webSearchInstruction =
    "IMPORTANTE: Hai accesso a Internet tramite il tag <search>query</search>. "
    "Se l'utente chiede notizie, meteo, fatti recenti, dati in tempo reale o informazioni che cambiano nel tempo, "
    "NON rispondere d'istinto. DEVI invocare una ricerca scrivendo ESCLUSIVAMENTE il tag <search>query di ricerca</search>. "
    "Non aggiungere altro prima o dopo il tag.";

class LocalPromptTemplates {
  LocalPromptTemplates._();

  static String compose({
    required String modelId,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const [],
  }) {
    final cleanedSystemPrompt = _clean(systemPrompt);

    // Iniezione forzata dell'istruzione di ricerca web nel system prompt
    final finalSystemPrompt =
        "${cleanedSystemPrompt ?? _completeSystemPrompt}\n\n$_webSearchInstruction";

    // Filtro contestuale centralizzato per il RAG locale e la memoria
    final cleanedContext = context
        .where(
          (turn) =>
              !turn.excludeFromContext && turn.content.trim().isNotEmpty,
        )
        .map((turn) => turn.copyWith(content: turn.content.trim()))
        .toList(growable: false);

    final userPrompt = prompt.trim();
    final template = LocalInferenceModelIds.resolveTemplate(modelId);
    final contextChars =
        cleanedContext.fold<int>(0, (sum, turn) => sum + turn.content.length);
    final webSystemPromptChars =
        finalSystemPrompt.contains('Web search results:')
            ? finalSystemPrompt.length
            : 0;

    RuntimeEventLog.instance.emit(
      '[PROMPT_BEGIN] model=$modelId prompt_chars=${userPrompt.length}',
    );
    RuntimeEventLog.instance.emit(
      '[PROMPT_SYSTEM_SIZE] chars=${finalSystemPrompt.length}',
    );
    RuntimeEventLog.instance.emit(
      '[PROMPT_CONTEXT_SIZE] turns=${cleanedContext.length} chars=$contextChars',
    );
    RuntimeEventLog.instance.emit(
      '[PROMPT_WEB_RESULTS_SIZE] chars=$webSystemPromptChars',
    );

    switch (template) {
      case 'llama3':
        return _buildLlama3Prompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      case 'qwen':
        return _buildQwenChatPrompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
          suppressThinking:
              LocalInferenceModelIds.isQwen3Thinking(modelId),
        );
      case 'gemma':
        return _buildGemmaPrompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      case 'phi3':
        return _buildPhi3Prompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      case 'zephyr':
        return _buildZephyrPrompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      default:
        final buffer = StringBuffer();

        buffer.writeln('');

        buffer.writeln('System: $finalSystemPrompt');
        buffer.writeln();

        for (final turn in cleanedContext) {
          buffer.writeln('${_roleName(turn.role)}: ${turn.content}');
        }
        if (cleanedContext.isNotEmpty) buffer.writeln();
        buffer.write('User: $userPrompt');
        final composed = buffer.toString();
        _logFinalPromptMetrics(composed, userPrompt.length);
        return composed;
    }
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _isFactualQuery(String prompt) {
    final p = prompt.toLowerCase();
    return p.contains('quanto') ||
        p.contains('quando') ||
        p.contains('chi è') ||
        p.contains('chi gioca') ||
        p.contains('dove') ||
        p.contains('cosè') ||
        p.contains('cosa è') ||
        p.contains('definizione') ||
        p.contains('colore') ||
        p.contains('cerca') ||
        p.contains('data') ||
        p.contains('anno') ||
        p.contains('meteo') ||
        p.contains('notizie');
  }

  static String _buildLlama3Prompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');
    buffer.write('<|begin_of_text|>');
    buffer.write('<|start_header_id|>system<|end_header_id|>\n\n');

    buffer.write(systemPrompt);
    buffer.write('<|eot_id|>');

    for (final turn in context) {
      buffer.write(
        '<|start_header_id|>${_roleName(turn.role)}<|end_header_id|>\n\n',
      );
      buffer.write(turn.content);
      buffer.write('<|eot_id|>');
    }

    buffer.write('<|start_header_id|>user<|end_header_id|>\n\n');
    buffer.write(userPrompt);
    buffer.write('<|eot_id|>');
    buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    final composed = buffer.toString();
    _logFinalPromptMetrics(composed, userPrompt.length);
    return composed;
  }

  static String _buildQwenChatPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
    bool suppressThinking = false,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');
    buffer.write('<|im_start|>system\n');

    buffer.write(systemPrompt);
    buffer.write('\n<|im_end|>\n');

    for (final turn in context) {
      buffer.write('<|im_start|>${_roleName(turn.role)}\n');
      buffer.write(turn.content);
      buffer.write('\n<|im_end|>\n');
    }

    final effectiveUserPrompt =
        suppressThinking ? '/no_think\n$userPrompt' : userPrompt;
    buffer.write('<|im_start|>user\n');
    buffer.write(effectiveUserPrompt);
    buffer.write('\n<|im_end|>\n');
    buffer.write('<|im_start|>assistant\n');
    final composed = buffer.toString();
    _logFinalPromptMetrics(composed, userPrompt.length);
    return composed;
  }

  static String _buildGemmaPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');

    buffer.write(
      '<start_of_turn>system\n$systemPrompt\n<end_of_turn>\n',
    );

    for (final turn in context) {
      buffer.write('<start_of_turn>${_gemmaRoleName(turn.role)}\n');
      buffer.write('${turn.content}\n');
      buffer.write('<end_of_turn>\n');
    }
    buffer.write('<start_of_turn>user\n$userPrompt\n<end_of_turn>\n');
    buffer.write('<start_of_turn>model\n');
    final composed = buffer.toString();
    _logFinalPromptMetrics(composed, userPrompt.length);
    return composed;
  }

  static String _buildPhi3Prompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.write(
      '<|system|>\n${systemPrompt.trim()}\n<|end|>\n',
    );

    for (final turn in context) {
      buffer.write('<|${_roleName(turn.role)}|>\n');
      buffer.write('${turn.content}\n');
      buffer.write('<|end|>\n');
    }

    buffer.write('<|user|>\n$userPrompt\n<|end|>\n');
    buffer.write('<|assistant|>\n');
    final composed = buffer.toString();
    _logFinalPromptMetrics(composed, userPrompt.length);
    return composed;
  }

  static String _buildZephyrPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');

    buffer.write('<|system|>\n$systemPrompt\n</s>\n');

    for (final turn in context) {
      final tag = _zephyrRoleName(turn.role);
      buffer.write('$tag\n${turn.content}\n</s>\n');
    }
    buffer.write('<|user|>\n$userPrompt\n</s>\n');
    buffer.write('<|assistant|>\n');
    final composed = buffer.toString();
    _logFinalPromptMetrics(composed, userPrompt.length);
    return composed;
  }

  static void _logFinalPromptMetrics(
    String composed,
    int userPromptChars,
  ) {
    RuntimeEventLog.instance.emit(
      '[PROMPT_FINAL_SIZE] chars=${composed.length}',
    );
    RuntimeEventLog.instance.emit(
      '[PROMPT_FINAL_TOKENS] estimate=${(composed.length / 4).ceil()}',
    );
    RuntimeEventLog.instance.emit(
      '[PROMPT_SENT] hash=${secureForensicHash(composed)} prompt_chars=$userPromptChars',
    );
  }

  static String _roleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return 'assistant';
      case ChatRole.system:
        return 'system';
      case ChatRole.user:
        return 'user';
    }
  }

  static String _gemmaRoleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return 'model';
      case ChatRole.system:
        return 'system';
      case ChatRole.user:
        return 'user';
    }
  }

  static String _zephyrRoleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return '<|assistant|>';
      case ChatRole.system:
        return '<|system|>';
      case ChatRole.user:
        return '<|user|>';
    }
  }
}
