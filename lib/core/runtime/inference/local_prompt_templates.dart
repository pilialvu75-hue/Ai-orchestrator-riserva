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

  // ===========================================================================
  // CONTEXT BUDGET
  // ===========================================================================
  //
  // AndroidFfiRuntimeProvider usa attualmente nCtx=2048.
  //
  // Non dobbiamo occupare tutto il context window con la history:
  //
  //   system prompt
  //   + history
  //   + current user prompt
  //   + generation headroom
  //
  // devono poter convivere nello stesso context.
  //
  // Il limite è intenzionalmente conservativo e si applica a TUTTE le famiglie.
  //
  // Non tronchiamo un messaggio a metà:
  // manteniamo solamente turni completi, partendo dai più recenti.
  //
  // Questo non modifica la memoria persistente: modifica solamente ciò che
  // viene inviato al modello per la singola inferenza.
  static const int _maxContextChars = 11000;
  static const int _maxContextTurns = 12;

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

    // -------------------------------------------------------------------------
    // Context cleaning
    // -------------------------------------------------------------------------
    //
    // Prima eliminiamo turni vuoti/esclusi.
    // Poi applichiamo il budget di contesto mantenendo i turni più recenti.
    //
    // IMPORTANTE:
    // il contesto filtrato non modifica request.context;
    // viene usata esclusivamente la lista locale per questa composizione.
    final cleanedContext = context
        .where(
          (turn) =>
              !turn.excludeFromContext &&
              turn.content.trim().isNotEmpty,
        )
        .map(
          (turn) => turn.copyWith(
            content: turn.content.trim(),
          ),
        )
        .toList(growable: false);

    final boundedContext = _boundContext(
      cleanedContext,
      maxChars: _maxContextChars,
      maxTurns: _maxContextTurns,
    );

    final template =
        LocalInferenceModelIds.resolveTemplate(modelId);

    final originalContextChars = cleanedContext.fold<int>(
      0,
      (sum, turn) => sum + turn.content.length,
    );

    final boundedContextChars = boundedContext.fold<int>(
      0,
      (sum, turn) => sum + turn.content.length,
    );

    final webSystemPromptChars =
        enableWebSearch ? finalSystemPrompt.length : 0;

    RuntimeEventLog.instance.emit(
      '[PROMPT_BEGIN] '
      'model=$modelId '
      'prompt_chars=${userPrompt.length}',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_SYSTEM_SIZE] '
      'chars=${finalSystemPrompt.length}',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_CONTEXT_SIZE] '
      'turns=${boundedContext.length} '
      'chars=$boundedContextChars '
      'original_turns=${cleanedContext.length} '
      'original_chars=$originalContextChars',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_CONTEXT_BOUND] '
      'applied=${boundedContext.length != cleanedContext.length || boundedContextChars != originalContextChars} '
      'max_chars=$_maxContextChars '
      'max_turns=$_maxContextTurns',
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_WEB_RESULTS_SIZE] '
      'chars=$webSystemPromptChars',
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
          context: boundedContext,
          userPrompt: userPrompt,
        );

      case LocalInferenceModelIds.templateQwen:
      case 'qwen': // Historical alias.
        return _buildQwenChatPrompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
          suppressThinking:
              LocalInferenceModelIds.isQwen3Thinking(modelId),
        );

      case 'deepseek':
        return _buildDeepSeekR1Prompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
        );

      case 'gemma':
        return _buildGemmaPrompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
        );

      case 'phi3':
        return _buildPhi3Prompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
        );

      case 'mistral':
        return _buildMistralPrompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
        );

      case 'zephyr':
        return _buildZephyrPrompt(
          systemPrompt: finalSystemPrompt,
          context: boundedContext,
          userPrompt: userPrompt,
        );

      default:
        final buffer = StringBuffer();

        buffer.writeln('');
        buffer.writeln('System: $finalSystemPrompt');
        buffer.writeln();

        for (final turn in boundedContext) {
          buffer.writeln(
            '${_roleName(turn.role)}: ${turn.content}',
          );
        }

        if (boundedContext.isNotEmpty) {
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

  // ===========================================================================
  // CONTEXT BOUNDING
  // ===========================================================================

  /// Mantiene il contesto più recente entro un budget conservativo.
  ///
  /// Il metodo:
  ///
  /// - non modifica la lista originale;
  /// - non tronca singoli messaggi;
  /// - mantiene i turni più recenti;
  /// - rispetta un limite sia di caratteri sia di numero di turni;
  /// - evita che una history molto lunga consumi tutto il context window.
  static List<ChatTurn> _boundContext(
    List<ChatTurn> context, {
    required int maxChars,
    required int maxTurns,
  }) {
    if (context.isEmpty) {
      return const [];
    }

    if (maxChars <= 0 || maxTurns <= 0) {
      return const [];
    }

    var usedChars = 0;
    var selected = <ChatTurn>[];

    /*
     * Partiamo dalla fine perché il contesto più recente ha il maggior
     * valore per una conversazione multi-turno.
     *
     * Non interrompiamo un messaggio a metà.
     */
    for (var index = context.length - 1;
        index >= 0 && selected.length < maxTurns;
        index--) {
      final turn = context[index];
      final contentLength = turn.content.length;

      if (contentLength == 0) {
        continue;
      }

      /*
       * Se il singolo turno supera il budget totale, non lo tronchiamo.
       * In questo caso non possiamo conservarlo insieme al resto della
       * history senza violare la regola "messaggi completi".
       *
       * Il prompt corrente resterà comunque sempre presente.
       */
      if (contentLength > maxChars) {
        continue;
      }

      if (usedChars + contentLength > maxChars) {
        continue;
      }

      selected.add(turn);
      usedChars += contentLength;
    }

    selected = selected.reversed.toList();
      
    return List<ChatTurn>.unmodifiable(selected);
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

  /// Template ufficiale DeepSeek-R1 / DeepSeek-R1-Distill-*.
  ///
  /// Basato sul chat_template ufficiale del tokenizer
  /// DeepSeek-R1-Distill-Qwen.
  ///
  /// Struttura:
  ///
  /// <｜begin▁of▁sentence｜>{system}
  /// <｜User｜>{user}
  /// <｜Assistant｜>{assistant}<｜end▁of▁sentence｜>
  /// ...
  /// <｜User｜>{current user}
  /// <｜Assistant｜><think>
  ///
  /// IMPORTANTE:
  ///
  /// - NON usare ChatML Qwen.
  /// - NON inserire EOS dopo il messaggio USER corrente.
  /// - I messaggi ASSISTANT già completati ricevono EOS.
  /// - La generazione corrente viene aperta con
  ///   <｜Assistant｜><think>\n.
  /// - Il BOS viene emesso esplicitamente.
  /// - DeepSeek-R1-Distill non usa /no_think.
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

    buffer.write(bos);

    if (systemPrompt.trim().isNotEmpty) {
      buffer.write(systemPrompt.trim());
    }

    for (final turn in context) {
      final content =
          _cleanDeepSeekAssistantContent(turn.content);

      if (content.isEmpty) {
        continue;
      }

      switch (turn.role) {
        case ChatRole.system:
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

    buffer.write(userTag);
    buffer.write(userPrompt);

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

  /// Rimuove il reasoning dalle risposte DeepSeek già presenti
  /// nella history.
  ///
  /// Conserviamo la risposta finale dopo </think>, evitando di
  /// trascinare il chain-of-thought nella conversazione successiva.
  static String _cleanDeepSeekAssistantContent(
    String content,
  ) {
    final trimmed = content.trim();

    if (trimmed.isEmpty) {
      return '';
    }

    final closingThink = trimmed.lastIndexOf('</think>');

    if (closingThink >= 0) {
      final finalAnswer =
          trimmed.substring(
            closingThink + '</think>'.length,
          ).trim();

      if (finalAnswer.isNotEmpty) {
        return finalAnswer;
      }

      return '';
    }

    return trimmed;
  }

  /// Template Mistral Instruct.
  ///
  /// Per la famiglia Mistral manteniamo il protocollo storico
  /// [INST] ... [/INST] con BOS <s> e EOS </s>.
  ///
  /// Formato tipico:
  ///
  /// <s>[INST] system
  ///
  /// user [/INST] assistant</s>
  /// [INST] next user [/INST] next assistant</s>
  ///
  /// Il system prompt viene incorporato nel primo blocco USER,
  /// coerentemente con il chat template Mistral 7B Instruct.
  static String _buildMistralPrompt({
    required String systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    const bos = '<s>';
    const eos = '</s>';
    const instOpen = '[INST]';
    const instClose = '[/INST]';

    final buffer = StringBuffer();

    buffer.write(bos);

    var systemText = systemPrompt.trim();

    final turns = <ChatTurn>[];

    for (final turn in context) {
      if (turn.role == ChatRole.system) {
        final content = turn.content.trim();

        if (content.isNotEmpty) {
          systemText = systemText.isEmpty
              ? content
              : '$systemText\n\n$content';
        }

        continue;
      }

      turns.add(turn);
    }

    /*
     * Mistral Instruct richiede alternanza user/assistant.
     *
     * Non ricostruiamo artificialmente turni mancanti e non
     * duplichiamo la history.
     */
    final normalizedTurns = <ChatTurn>[];
    ChatRole? previousRole;

    for (final turn in turns) {
      if (previousRole == turn.role) {
        final previous = normalizedTurns.removeLast();

        final mergedContent =
            '${previous.content.trim()}\n\n${turn.content.trim()}';

        normalizedTurns.add(
          previous.copyWith(
            content: mergedContent.trim(),
          ),
        );
      } else {
        normalizedTurns.add(turn);
        previousRole = turn.role;
      }
    }

    for (final turn in normalizedTurns) {
      if (turn.role == ChatRole.user) {
        var userContent = turn.content.trim();

        if (systemText.isNotEmpty &&
            buffer.length == bos.length) {
          userContent =
              '$systemText\n\n$userContent';
        }

        buffer.write(
          '$instOpen $userContent $instClose',
        );
      } else if (turn.role == ChatRole.assistant) {
        buffer.write(
          ' ${turn.content.trim()}$eos',
        );
      }
    }

    var currentUserContent = userPrompt;

    if (systemText.isNotEmpty &&
        normalizedTurns.isEmpty) {
      currentUserContent =
          '$systemText\n\n$currentUserContent';
    }

    buffer.write(
      '$instOpen $currentUserContent $instClose',
    );

    final composed = buffer.toString();

    _logFinalPromptMetrics(
      composed,
      userPrompt.length,
    );

    RuntimeEventLog.instance.emit(
      '[PROMPT_TEMPLATE_MISTRAL] '
      'bos=true '
      'inst=true '
      'context_turns=${normalizedTurns.length}',
    );

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
