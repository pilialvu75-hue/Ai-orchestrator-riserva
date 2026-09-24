import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';

/// Controller della conversazione del Cantiere.
///
/// Il Workshop possiede una propria conversazione indipendente
/// dalla Chat Assistente.
///
/// Responsabilità:
///
///   Workshop UI
///        ↓
///   WorkshopChatController
///        ↓
///   WorkshopInferenceGateway
///        ↓
///   RuntimeInferenceProvider
///
/// La lista [messages] rappresenta esclusivamente la memoria
/// conversazionale temporanea della sessione corrente.
///
/// IMPORTANTE:
///
/// - non utilizza la cronologia dell'Assistente;
/// - non persiste automaticamente la conversazione;
/// - non contiene logica di ProjectPlan;
/// - non modifica il Workspace;
/// - non applica modifiche al repository;
/// - non decide quale modello usare.
///
/// La scelta del modello rimane responsabilità del livello
/// di inferenza/configurazione del Cantiere.
enum WorkshopChatReplyKind {
  clarification,
  proposal,
}

final class _WorkshopParsedReply {
  const _WorkshopParsedReply({
    required this.kind,
    required this.content,
  });

  final WorkshopChatReplyKind kind;
  final String content;
}

final class WorkshopChatController extends ChangeNotifier {
  WorkshopChatController({
    required WorkshopInferenceGateway inferenceGateway,
    String sessionId = 'workshop',
    String systemPrompt =
        'Sei il Cantiere, un ambiente indipendente di progettazione e costruzione. '
        'Dialoga con l\'utente e comprendi cosa vuole realizzare. Se manca un '
        'dato davvero necessario, rispondi iniziando esattamente con "CLARIFY:" '
        'e fai solo le domande indispensabili. Quando hai informazioni sufficienti, '
        'rispondi iniziando esattamente con "PROPOSAL:" e fornisci una proposta '
        'completa e operativa per il piu piccolo MVP realmente costruibile. '
        'Non aggiungere funzionalita, sensori, servizi, permessi, API, cloud o '
        'integrazioni che l\'utente non ha richiesto esplicitamente. Non assumere '
        'capacita hardware del dispositivo che non sono state verificate. Se la '
        'richiesta e ampia, limita la proposta approvabile al primo incremento '
        'funzionante; eventuali evoluzioni future non fanno parte dei requisiti '
        'del task corrente. Rispondi sempre nella stessa lingua dell\'ultimo '
        'messaggio dell\'utente e non cambiare lingua tra chiarimenti e proposta. '
        'Se il messaggio corrente e in italiano, rispondi in italiano; non '
        'tradurlo in portoghese, spagnolo o altre lingue. Non chiedere conferma '
        'nella risposta: la conferma e gestita dall\'interfaccia del Cantiere. '
        'Non dichiarare mai che qualcosa e stato costruito, testato o compilato '
        'se non e realmente avvenuto.',
  })  : _inferenceGateway = inferenceGateway,
        _sessionId = sessionId.trim().isEmpty
            ? 'workshop'
            : sessionId.trim(),
        _systemPrompt = systemPrompt;

  final WorkshopInferenceGateway _inferenceGateway;
  final String _sessionId;
  final String _systemPrompt;

  final List<ChatTurn> _messages = <ChatTurn>[];

  bool _isBusy = false;
  bool _disposed = false;

  String? _lastError;
  String? _lastRuntimeNotice;
  String? _lastModel;
  WorkshopChatReplyKind? _lastReplyKind;

  /// Conversazione corrente del Cantiere.
  ///
  /// Restituisce una copia non modificabile.
  List<ChatTurn> get messages =>
      List<ChatTurn>.unmodifiable(_messages);

  bool get isBusy => _isBusy;

  bool get hasMessages => _messages.isNotEmpty;

  bool get hasError =>
      _lastError != null &&
      _lastError!.trim().isNotEmpty;

  String? get lastError => _lastError;

  String? get lastRuntimeNotice =>
      _lastRuntimeNotice;

  String? get lastModel => _lastModel;

  WorkshopChatReplyKind? get lastReplyKind => _lastReplyKind;

  bool get lastResponseReadyForApproval =>
      _lastReplyKind == WorkshopChatReplyKind.proposal;

  String get sessionId => _sessionId;

  /// Invia un nuovo messaggio al Cantiere.
  ///
  /// Il flusso è:
  ///
  ///   user message
  ///        ↓
  ///   Workshop context
  ///        ↓
  ///   LLM
  ///        ↓
  ///   assistant response
  ///
  /// Per default il Cantiere non forza l'offline: Local / Cloud / Hybrid
  /// restano decisioni del runtime. [isOffline] rimane disponibile solo per
  /// chiamanti che vogliono esplicitamente impedire l'uso della rete.
  Future<ChatTurn?> send(
    String message, {
    String? modelId,
    String? modelPath,
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
  }) async {
    _ensureNotDisposed();

    final normalizedMessage =
        message.trim();

    if (normalizedMessage.isEmpty) {
      return null;
    }

    if (_isBusy) {
      return null;
    }

    _lastError = null;
    _lastRuntimeNotice = null;
    _lastReplyKind = null;

    final userTurn = ChatTurn(
      role: ChatRole.user,
      content: normalizedMessage,
    );

    _messages.add(userTurn);

    _setBusy(true);

    try {
      // The current user turn is carried by InferenceRequest.prompt.
      // Keep only prior Workshop turns in context, otherwise prompt composers
      // render the same user text once from context and once as the current
      // prompt. Besides causing visible repetition, that duplicate also makes
      // local prefill unnecessarily larger and increases stall risk.
      final context =
          List<ChatTurn>.unmodifiable(
        _messages.length <= 1
            ? const <ChatTurn>[]
            : _messages.sublist(
                0,
                _messages.length - 1,
              ),
      );

      final result =
          await _inferenceGateway.complete(
        prompt: normalizedMessage,
        systemPrompt: _systemPrompt,
        context: context,
        sessionId: _sessionId,
        isOffline: isOffline,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        repeatPenalty: repeatPenalty,
        modelId: modelId,
        modelPath: modelPath,
      );

      if (result.runtimeNotice != null &&
          result.runtimeNotice!
              .trim()
              .isNotEmpty) {
        _lastRuntimeNotice =
            result.runtimeNotice;
      }

      if (result.model != null &&
          result.model!.trim().isNotEmpty) {
        _lastModel = result.model;
      }

      if (result.hasError) {
        final rawError = result.errorMessage;
        if (_isTechnicalRuntimeError(rawError)) {
          // Preserve the protocol-level runtime evidence for diagnostics while
          // keeping the conversational UI user-safe and readable.
          _lastRuntimeNotice ??= rawError!.trim();
        }

        _lastError = _userFacingInferenceError(rawError);

        _removeLastUserTurn();

        return null;
      }

      if (!result.hasText) {
        _lastError =
            'Il modello del Cantiere non ha restituito una risposta.';

        _removeLastUserTurn();

        return null;
      }

      final parsed = _parseReply(result.text);
      _lastReplyKind = parsed.kind;

      final assistantTurn = ChatTurn(
        role: ChatRole.assistant,
        content: parsed.content,
      );

      _messages.add(assistantTurn);

      return assistantTurn;
    } catch (_) {
      _lastError =
          'Errore nella conversazione del Cantiere. Riprova.';

      _removeLastUserTurn();

      return null;
    } finally {
      _setBusy(false);
    }
  }

  static _WorkshopParsedReply _parseReply(String rawText) {
    final normalized = rawText.trim();
    final upper = normalized.toUpperCase();

    const clarifyPrefix = 'CLARIFY:';
    const proposalPrefix = 'PROPOSAL:';

    if (upper.startsWith(clarifyPrefix)) {
      final content = normalized.substring(clarifyPrefix.length).trim();
      return _WorkshopParsedReply(
        kind: WorkshopChatReplyKind.clarification,
        content: content.isEmpty ? normalized : content,
      );
    }

    if (upper.startsWith(proposalPrefix)) {
      final content = normalized.substring(proposalPrefix.length).trim();
      return _WorkshopParsedReply(
        kind: content.isEmpty
            ? WorkshopChatReplyKind.clarification
            : WorkshopChatReplyKind.proposal,
        content: content.isEmpty ? normalized : content,
      );
    }

    // Conservative compatibility fallback for models/builds that do not yet
    // obey the explicit reply prefix. A response ending as a direct question
    // is not safe to treat as an owner-approvable production proposal.
    return _WorkshopParsedReply(
      kind: normalized.endsWith('?')
          ? WorkshopChatReplyKind.clarification
          : WorkshopChatReplyKind.proposal,
      content: normalized,
    );
  }

  static bool _isTechnicalRuntimeError(String? rawError) {
    final normalized = rawError?.trim();
    return normalized != null &&
        normalized.startsWith('AI_RUNTIME_ERROR|');
  }

  static String _userFacingInferenceError(String? rawError) {
    final normalized = rawError?.trim();

    if (normalized == null || normalized.isEmpty) {
      return 'Il modello del Cantiere ha restituito un errore. Riprova.';
    }

    if (!normalized.startsWith('AI_RUNTIME_ERROR|')) {
      return normalized;
    }

    if (normalized.contains('|stage=stalled|')) {
      return 'Il modello del Cantiere si e fermato durante l\'elaborazione. '
          'Riprova.';
    }

    if (normalized.contains('|stage=timeout|')) {
      return 'Il modello del Cantiere ha impiegato troppo tempo a rispondere. '
          'Riprova.';
    }

    if (normalized.contains('|stage=cancelled|')) {
      return 'L\'elaborazione del Cantiere e stata annullata.';
    }

    return 'Il runtime del Cantiere non ha completato la risposta. Riprova.';
  }

  /// Aggiunge un turno di sistema visibile nella conversazione.
  ///
  /// I turni inseriti con [excludeFromContext] non vengono inviati al modello
  /// nei messaggi successivi.
  void addSystemMessage(
    String message, {
    bool excludeFromContext = true,
  }) {
    _ensureNotDisposed();

    final normalizedMessage =
        message.trim();

    if (normalizedMessage.isEmpty) {
      return;
    }

    _messages.add(
      ChatTurn(
        role: ChatRole.system,
        content: normalizedMessage,
        excludeFromContext: excludeFromContext,
      ),
    );

    notifyListeners();
  }

  /// Cancella esclusivamente la memoria conversazionale della sessione.
  ///
  /// NON cancella la memoria persistente del progetto.
  ///
  /// Questo metodo implementa la regola:
  ///
  ///   fine sessione
  ///        ↓
  ///   memoria chat temporanea azzerata
  ///
  /// La Project Memory sarà gestita da un componente separato.
  void clearConversation() {
    _ensureNotDisposed();

    _messages.clear();

    _lastError = null;
    _lastRuntimeNotice = null;
    _lastModel = null;
    _lastReplyKind = null;

    notifyListeners();
  }

  /// Rimuove l'ultimo messaggio utente quando una richiesta non ha prodotto
  /// una risposta valida.
  ///
  /// In questo modo la conversazione non conserva una richiesta che
  /// il Cantiere non è riuscito a prendere in carico.
  void _removeLastUserTurn() {
    if (_messages.isNotEmpty &&
        _messages.last.role ==
            ChatRole.user) {
      _messages.removeLast();
    }

    _lastReplyKind = null;
    notifyListeners();
  }

  void _setBusy(
    bool busy,
  ) {
    if (_disposed) {
      return;
    }

    _isBusy = busy;
    notifyListeners();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError(
        'WorkshopChatController has been disposed.',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;

    _messages.clear();

    super.dispose();
  }
}
