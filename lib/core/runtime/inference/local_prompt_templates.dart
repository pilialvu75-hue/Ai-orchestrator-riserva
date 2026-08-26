import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_forensics.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

const String _completeSystemPrompt =
    'You are a helpful assistant. Give complete answers when appropriate.';

// Istruzione per l'abilitazione della ricerca web.
// Viene aggiunta SOLO quando la richiesta è realmente fattuale/dinamica.
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

    final userPrompt = prompt.trim();

    /*
     * IMPORTANT:
     *
     * The web-search protocol must NOT be injected into every prompt.
     *
     * Previously the instruction was always appended to the system prompt.
     * That caused simple requests such as:
     *
     *   "ciao"
     *   "cavolo"
     *
     * to be interpreted by the local model as search requests.
     *
     * The search instruction is now enabled only for prompts that are
     * actually likely to require factual/current information.
     */
    final enableWebSearch = _isFactualQuery(userPrompt);

    final baseSystemPrompt =
        cleanedSystemPrompt ?? _completeSystemPrompt;

    final finalSystemPrompt = enableWebSearch
        ? '$baseSystemPrompt\n\n$_webSearchInstruction'
        : baseSystemPrompt;

    // Filtro contestuale centralizzato per il RAG locale e la memoria.
    final cleanedContext = context
        .where(
          (turn) =>
              !turn.excludeFromContext && turn.content.trim().isNotEmpty,
        )
        .map((turn) => turn.copyWith(content: turn.content.trim()))
        .toList(growable: false);

    final template = LocalInferenceModelIds.resolveTemplate(modelId);

    final contextChars = cleanedContext.fold<int>(
      0,
      (sum, turn) => sum + turn.content.length,
    );

    final webSystemPromptChars = enableWebSearch
        ? finalSystemPrompt.length
        : 0;

    RuntimeEventLog.instance.emit(
      '[PROMPT_BEGIN] model=$modelId prompt_chars=${userPrompt.length}',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_SYSTEM_SIZE] chars=${finalSystemPrompt.length}',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_CONTEXT_SIZE] '
      'turns=${cleanedContext.length} '
      'chars=$contextChars',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_WEB_RESULTS_SIZE] chars=$webSystemPromptChars',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_WEB_SEARCH] '
      'enabled=$enableWebSearch '
      'reason=${enableWebSearch ? 'factual_query' : 'ordinary_conversation'}',
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

      case 'deepseek':
        return _buildDeepSeekR1Prompt(
          systemPrompt: finalSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
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
          buffer.writeln(
            '${_roleName(turn.role)}: ${turn.content}',
          );
        }

        if (cleanedContext.isNotEmpty) {
          buffer.writeln();
        }

        buffer.write('User: $userPrompt');

        final composed = buffer.toString();

        _logFinalPromptMetrics(
          composed,
          userPrompt.length,
        );

        return composed;
    }
  }

  static String? _clean(String? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.trim();

    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _isFactualQuery(String prompt) {
    final p = prompt.trim().toLowerCase();

    if (p.isEmpty) {
      return false;
    }

    /*
     * Keep this deliberately conservative.
     *
     * Ordinary conversational messages such as:
     *
     *   ciao
     *   cavolo
     *   grazie
     *   ok
     *
     * must NOT activate the search protocol.
     *
     * Search activation is reserved for explicit factual/current
     * information requests.
     */

    return p.contains('quanto') ||
        p.contains('quando') ||
        p.contains('chi è') ||
        p.contains('chi e ') ||
        p.contains('chi gioca') ||
        p.contains('dove') ||
        p.contains('cosè') ||
        p.contains('cos\'è') ||
        p.contains('cosa è') ||
        p.contains('cosa sono') ||
        p.contains('definizione') ||
        p.contains('colore') ||
        p.contains('cerca') ||
        p.contains('cercami') ||
        p.contains('ricerca') ||
        p.contains('trova') ||
        p.contains('data') ||
        p.contains('anno') ||
        p.contains('meteo') ||
        p.contains('notizie') ||
        p.contains('news') ||
        p.contains('oggi') ||
        p.contains('attuale') ||
        p.contains('attualmente') ||
        p.contains('ultimo') ||
        p.contains('ultima') ||
        p.contains('ultime') ||
        p.contains('recente') ||
        p.contains('recenti') ||
        p.contains('in tempo reale') ||
        p.contains('tempo reale');
  }

  static String _buildLlama3Prompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');
    buffer.write('<|begin_of_text|>');
    buffer.write(
      '<|start_header_id|>system<|end_header_id|>\n\n',
    );

    buffer.write(systemPrompt);
    buffer.write('<|eot_id|>');

    for (final turn in context) {
      buffer.write(
        '<|start_header_id|>${_roleName(turn.role)}'
        '<|end_header_id|>\n\n',
      );

      buffer.write(turn.content);
      buffer.write('<|eot_id|>');
    }

    buffer.write(
      '<|start_header_id|>user<|end_header_id|>\n\n',
    );

    buffer.write(userPrompt);
    buffer.write('<|eot_id|>');

    buffer.write(
      '<|start_header_id|>assistant<|end_header_id|>\n\n',
    );

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

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
      buffer.write(
        '<|im_start|>${_roleName(turn.role)}\n',
      );

      buffer.write(turn.content);
      buffer.write('\n<|im_end|>\n');
    }

    final effectiveUserPrompt = suppressThinking
        ? '/no_think\n$userPrompt'
        : userPrompt;

    buffer.write('<|im_start|>user\n');
    buffer.write(effectiveUserPrompt);
    buffer.write('\n<|im_end|>\n');
    buffer.write('<|im_start|>assistant\n');

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

    return composed;
  }

  /// Template DeepSeek-R1 / DeepSeek-R1-Distill-*.
  ///
  /// Il formato è basato sul chat_template dichiarato dai tokenizer
  /// DeepSeek-R1-Distill e sul template DeepSeek utilizzato da llama.cpp.
  ///
  /// Struttura:
  ///
  ///   <｜begin▁of▁sentence｜>
  ///   {system}
  ///   <｜User｜>{user}<｜end▁of▁sentence｜>
  ///   <｜Assistant｜>{assistant}<｜end▁of▁sentence｜>
  ///   ...
  ///   <｜User｜>{current user}<｜end▁of▁sentence｜>
  ///   <｜Assistant｜><think>
  ///
  /// Importante:
  /// - DeepSeek-R1 non usa ChatML Qwen.
  /// - Il BOS viene emesso esplicitamente.
  /// - I turni già completati ricevono EOS.
  /// - Il turno corrente termina prima dell'assistant generation prompt.
  /// - La generazione viene aperta con <think>, coerentemente con
  ///   il comportamento reasoning di DeepSeek-R1.
  /// - Non viene usato /no_think: è una direttiva propria di Qwen3,
  ///   non di DeepSeek-R1-Distill.
  ///
  /// La scelta del template avviene tramite LocalInferenceModelIds:
  /// quindi la stessa funzione è valida per DeepSeek 1.5B, 7B,
  /// 14B, 32B, 70B e futuri GGUF della stessa famiglia.
  static String _buildDeepSeekR1Prompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    const bos = '<｜begin▁of▁sentence｜>';
    const userTag = '<｜User｜>';
    const assistantTag = '<｜Assistant｜>';
    const eos = '<｜end▁of▁sentence｜>';

    final buffer = StringBuffer();

    // BOS ufficiale DeepSeek.
    buffer.write(bos);

    // Nel template ufficiale il system prompt segue direttamente il BOS.
    if (systemPrompt.trim().isNotEmpty) {
      buffer.write(systemPrompt.trim());
    }

    for (final turn in context) {
      final content = _cleanDeepSeekAssistantContent(turn.content);

      if (content.isEmpty) {
        continue;
      }

      switch (turn.role) {
        case ChatRole.system:
          /*
           * Il template DeepSeek raccoglie il system prompt all'inizio.
           * Un eventuale system turn presente nella history non deve
           * diventare un falso ruolo "system" che il modello non conosce.
           *
           * Lo manteniamo come testo continuo, evitando di introdurre
           * marker conversazionali non supportati.
           */
          buffer.write(content);
          break;

        case ChatRole.user:
          buffer.write(userTag);
          buffer.write(content);
          buffer.write(eos);
          break;

        case ChatRole.assistant:
          buffer.write(assistantTag);
          buffer.write(content);
          buffer.write(eos);
          break;
      }
    }

    // Turno corrente dell'utente.
    buffer.write(userTag);
    buffer.write(userPrompt);
    buffer.write(eos);

    /*
     * Generation prompt DeepSeek-R1.
     *
     * Il modello reasoning viene aperto con <think>. Il contenuto
     * del reasoning sarà successivamente gestito dalla pipeline
     * output/sanity già esistente.
     */
    buffer.write(assistantTag);
    buffer.write('<think>\n');

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_TEMPLATE_DEEPSEEK] '
      'bos=true '
      'reasoning_prompt=true '
      'context_turns=${context.length}',
    );

    return composed;
  }

  /// Rimuove il blocco di reasoning dalle risposte DeepSeek già presenti
  /// nella history.
  ///
  /// Il template ufficiale DeepSeek e quello di llama.cpp trattano
  /// `</think>` come separatore del reasoning. Per la history chat
  /// vogliamo conservare la risposta finale, non trascinare nuovamente
  /// tutto il chain-of-thought nel prompt successivo.
  static String _cleanDeepSeekAssistantContent(String content) {
    final trimmed = content.trim();

    if (trimmed.isEmpty) {
      return '';
    }

    final closingThink = trimmed.lastIndexOf('</think>');

    if (closingThink >= 0) {
      final finalAnswer =
          trimmed.substring(closingThink + '</think>'.length).trim();

      if (finalAnswer.isNotEmpty) {
        return finalAnswer;
      }

      return '';
    }

    return trimmed;
  }

  static String _buildGemmaPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');

    buffer.write(
      '<start_of_turn>system\n'
      '$systemPrompt\n'
      '<end_of_turn>\n',
    );

    for (final turn in context) {
      buffer.write(
        '<start_of_turn>${_gemmaRoleName(turn.role)}\n',
      );

      buffer.write('${turn.content}\n');
      buffer.write('<end_of_turn>\n');
    }

    buffer.write(
      '<start_of_turn>user\n'
      '$userPrompt\n'
      '<end_of_turn>\n',
    );

    buffer.write('<start_of_turn>model\n');

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

    return composed;
  }

  static String _buildPhi3Prompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.write(
      '<|system|>\n'
      '${systemPrompt.trim()}\n'
      '<|end|>\n',
    );

    for (final turn in context) {
      buffer.write(
        '<|${_roleName(turn.role)}|>\n',
      );

      buffer.write('${turn.content}\n');
      buffer.write('<|end|>\n');
    }

    buffer.write(
      '<|user|>\n'
      '$userPrompt\n'
      '<|end|>\n',
    );

    buffer.write('<|assistant|>\n');

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

    return composed;
  }

  static String _buildZephyrPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('');

    buffer.write(
      '<|system|>\n'
      '$systemPrompt\n'
      '</s>\n',
    );

    for (final turn in context) {
      final tag = _zephyrRoleName(turn.role);

      buffer.write(
        '$tag\n'
        '${turn.content}\n'
        '</s>\n',
      );
    }

    buffer.write(
      '<|user|>\n'
      '$userPrompt\n'
      '</s>\n',
    );

    buffer.write('<|assistant|>\n');

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

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
      '[PROMPT_FINAL_TOKENS] '
      'estimate=${(composed.length / 4).ceil()}',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_SENT] '
      'hash=${secureForensicHash(composed)} '
      'prompt_chars=$userPromptChars',
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
