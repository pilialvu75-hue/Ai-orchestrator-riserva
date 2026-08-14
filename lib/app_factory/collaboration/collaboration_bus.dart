import 'dart:async';

/// Identifica il sistema che sta producendo o ricevendo un messaggio
/// di collaborazione.
enum CollaborationParticipant {
  assistant,
  orchestrator,
  architect,
  engineer,
  workshop,
  externalAi,
  user,
}

/// Tipo di messaggio scambiato tra Assistente/A-team e Cantiere.
enum CollaborationMessageType {
  request,
  instruction,
  context,
  proposal,
  review,
  validation,
  result,
  warning,
  error,
  status,
}

/// Messaggio interno di collaborazione.
///
/// Questo modello NON esegue azioni.
/// Trasporta solamente informazioni tra i diversi sottosistemi.
///
/// La separazione è intenzionale:
///
///   CHAT ASSISTENTE
///        │
///        ▼
///   A-TEAM / ORCHESTRATOR
///        │
///        ▼
///   COLLABORATION BUS
///        │
///        ▼
///   CHAT CANTIERE
///
/// Il Cantiere può quindi funzionare anche senza A-team:
/// in quel caso riceve direttamente il lavoro dell'utente.
final class CollaborationMessage {
  const CollaborationMessage({
    required this.id,
    required this.timestamp,
    required this.source,
    required this.target,
    required this.type,
    required this.content,
    this.sessionId,
    this.projectId,
    this.metadata = const <String, String>{},
  });

  final String id;
  final DateTime timestamp;

  /// Sistema che ha prodotto il messaggio.
  final CollaborationParticipant source;

  /// Sistema destinatario.
  final CollaborationParticipant target;

  final CollaborationMessageType type;

  /// Contenuto naturale del messaggio.
  final String content;

  /// Sessione di lavoro a cui appartiene il messaggio.
  final String? sessionId;

  /// Progetto/applicazione a cui appartiene il messaggio.
  final String? projectId;

  /// Metadati leggeri per evitare di inserire logica nel bus.
  final Map<String, String> metadata;

  CollaborationMessage copyWith({
    String? id,
    DateTime? timestamp,
    CollaborationParticipant? source,
    CollaborationParticipant? target,
    CollaborationMessageType? type,
    String? content,
    String? sessionId,
    String? projectId,
    Map<String, String>? metadata,
  }) {
    return CollaborationMessage(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      source: source ?? this.source,
      target: target ?? this.target,
      type: type ?? this.type,
      content: content ?? this.content,
      sessionId: sessionId ?? this.sessionId,
      projectId: projectId ?? this.projectId,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Bus interno leggero per la collaborazione tra Assistente/A-team
/// e Cantiere.
///
/// IMPORTANTISSIMO:
///
/// Questo componente NON:
/// - accede a GitHub;
/// - modifica file;
/// - esegue commit;
/// - esegue build;
/// - chiama direttamente un LLM;
/// - modifica la chat assistente.
///
/// Fa solamente da trasporto.
///
/// In questo modo possiamo cambiare completamente:
/// - la chat assistente;
/// - l'A-team;
/// - il Cantiere;
/// - il provider AI;
///
/// senza dover riscrivere il canale di comunicazione.
final class CollaborationBus {
  CollaborationBus._();

  /// Singleton applicativo.
///
/// Il bus non mantiene stato di progetto permanente.
  /// Conserva solamente una piccola coda in memoria per le sessioni attive.
  static final CollaborationBus instance = CollaborationBus._();

  final StreamController<CollaborationMessage> _controller =
      StreamController<CollaborationMessage>.broadcast();

  final List<CollaborationMessage> _recentMessages =
      <CollaborationMessage>[];

  /// Limite deliberatamente basso:
  /// il bus non deve diventare un secondo sistema di memoria.
  static const int maxRecentMessages = 100;

  /// Stream globale dei messaggi.
  Stream<CollaborationMessage> get stream => _controller.stream;

  /// Snapshot dei messaggi recenti.
  List<CollaborationMessage> get recentMessages =>
      List.unmodifiable(_recentMessages);

  /// Invia un messaggio sul bus.
  ///
  /// Il bus non decide cosa fare del messaggio.
  void publish(CollaborationMessage message) {
    if (_recentMessages.length >= maxRecentMessages) {
      _recentMessages.removeAt(0);
    }

    _recentMessages.add(message);

    if (!_controller.isClosed) {
      _controller.add(message);
    }
  }

  /// Crea e pubblica rapidamente un messaggio.
  CollaborationMessage send({
    required CollaborationParticipant source,
    required CollaborationParticipant target,
    required CollaborationMessageType type,
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    final message = CollaborationMessage(
      id: _createMessageId(),
      timestamp: DateTime.now(),
      source: source,
      target: target,
      type: type,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: Map.unmodifiable(
        Map<String, String>.from(metadata),
      ),
    );

    publish(message);
    return message;
  }

  /// Ascolta solamente i messaggi destinati a [participant].
  Stream<CollaborationMessage> messagesFor(
    CollaborationParticipant participant,
  ) {
    return stream.where(
      (message) => message.target == participant,
    );
  }

  /// Ascolta i messaggi relativi a una determinata sessione.
  Stream<CollaborationMessage> messagesForSession(
    String sessionId,
  ) {
    return stream.where(
      (message) => message.sessionId == sessionId,
    );
  }

  /// Ascolta i messaggi relativi a un determinato progetto.
  Stream<CollaborationMessage> messagesForProject(
    String projectId,
  ) {
    return stream.where(
      (message) => message.projectId == projectId,
    );
  }

  /// Restituisce gli ultimi messaggi di una sessione.
  List<CollaborationMessage> recentMessagesForSession(
    String sessionId, {
    int limit = 20,
  }) {
    final result = _recentMessages
        .where((message) => message.sessionId == sessionId)
        .toList();

    if (result.length <= limit) {
      return List.unmodifiable(result);
    }

    return List.unmodifiable(
      result.sublist(result.length - limit),
    );
  }

  /// Cancella solamente lo storico volatile del bus.
  ///
  /// Non cancella:
  /// - memoria dell'assistente;
  /// - memoria del Cantiere;
  /// - file del progetto;
  /// - repository;
  /// - log diagnostici persistenti.
  void clearRecentMessages() {
    _recentMessages.clear();
  }

  /// Chiude il bus.
  ///
  /// Da utilizzare solamente durante lo shutdown dell'applicazione.
  Future<void> dispose() async {
    await _controller.close();
  }

  static String _createMessageId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'collab_$now';
  }
}
