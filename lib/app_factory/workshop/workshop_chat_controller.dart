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
final class WorkshopChatController extends ChangeNotifier {
  WorkshopChatController({
    required WorkshopInferenceGateway inferenceGateway,
    String sessionId = 'workshop',
    String systemPrompt =
        'Sei il Cantiere, un ambiente indipendente di progettazione e costruzione. '
        'Dialoga con l\'utente, comprendi cosa vuole realizzare, proponi una soluzione '
        'chiara e chiedi conferma prima di iniziare la costruzione. '
        'Non dichiarare mai che qualcosa è stato costruito, testato o compilato '
        'se non è realmente avvenuto.',
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
  /// Questa prima versione utilizza [complete] del gateway, mantenendo
  /// comunque il contratto di streaming già disponibile sotto.
  Future<ChatTurn?> send(
    String message, {
    String? modelId,
    String? modelPath,
    bool isOffline = true,
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

    final userTurn = ChatTurn(
      role: ChatRole.user,
      content: normalizedMessage,
    );

    _messages.add(userTurn);

    _setBusy(true);

    try {
      final context =
          List<ChatTurn>.unmodifiable(
        _messages,
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
        _lastError =
            result.errorMessage ??
                'Il modello del Cantiere ha restituito un errore.';

        _removeLastUserTurn();

        return null;
      }

      if (!result.hasText) {
        _lastError =
            'Il modello del Cantiere non ha restituito una risposta.';

        _removeLastUserTurn();

        return null;
      }

      final assistantTurn = ChatTurn(
        role: ChatRole.assistant,
        content: result.text.trim(),
      );

      _messages.add(assistantTurn);

      return assistantTurn;
    } catch (error) {
      _lastError =
          'Errore nella conversazione del Cantiere: $error';

      _removeLastUserTurn();

      return null;
    } finally {
      _setBusy(false);
    }
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
