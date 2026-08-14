import 'collaboration_bus.dart';

/// Destinazione logica di una richiesta proveniente dall'Assistente
/// o dal Cantiere.
///
/// Il router decide solamente DOVE deve andare una richiesta.
/// Non esegue LLM, non modifica file e non accede a GitHub.
enum CollaborationRoute {
  workshop,
  assistant,
  orchestrator,
  architect,
  engineer,
  externalAi,
}

/// Risultato della classificazione di una richiesta.
final class CollaborationRoutingDecision {
  const CollaborationRoutingDecision({
    required this.route,
    required this.reason,
  });

  final CollaborationRoute route;
  final String reason;

  bool get isWorkshop => route == CollaborationRoute.workshop;
}

/// Router leggero tra Assistente/A-team e Cantiere.
///
/// Principio architetturale:
///
///   ASSISTENTE
///       │
///       ▼
///   ORCHESTRATORE
///       │
///       ├── ARCHITETTO
///       ├── INGEGNERE
///       ├── AI ESTERNE
///       │
///       ▼
///   COLLABORATION ROUTER
///       │
///       ▼
///   CANTIERE
///
/// Il Cantiere resta comunque autonomo:
///
///   UTENTE → CANTIERE
///
/// è un percorso valido anche quando l'Assistente/A-team non è disponibile.
final class CollaborationRouter {
  CollaborationRouter({
    CollaborationBus? bus,
  }) : _bus = bus ?? CollaborationBus.instance;

  final CollaborationBus _bus;

  /// Invia una richiesta direttamente al Cantiere.
  ///
  /// Questo è il percorso principale quando l'utente lavora direttamente
  /// nella Chat Cantiere.
  CollaborationMessage sendToWorkshop({
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: CollaborationParticipant.user,
      target: CollaborationParticipant.workshop,
      type: CollaborationMessageType.request,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia istruzioni preparate dall'Assistente/A-team al Cantiere.
  ///
  /// Il Cantiere deve poter utilizzare queste istruzioni senza dipendere
  /// dall'esistenza del processo che le ha generate.
  CollaborationMessage sendWorkshopInstruction({
    required CollaborationParticipant source,
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: source,
      target: CollaborationParticipant.workshop,
      type: CollaborationMessageType.instruction,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia una richiesta dall'Assistente all'Orchestratore.
  CollaborationMessage requestOrchestration({
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: CollaborationParticipant.assistant,
      target: CollaborationParticipant.orchestrator,
      type: CollaborationMessageType.request,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia una richiesta di progettazione all'Architetto.
  CollaborationMessage requestArchitecture({
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: CollaborationParticipant.orchestrator,
      target: CollaborationParticipant.architect,
      type: CollaborationMessageType.request,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia una richiesta tecnica all'Ingegnere.
  CollaborationMessage requestEngineering({
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: CollaborationParticipant.orchestrator,
      target: CollaborationParticipant.engineer,
      type: CollaborationMessageType.request,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia un risultato del Cantiere all'Orchestratore.
  ///
  /// Serve per il futuro ciclo:
  ///
  /// richiesta → costruzione → validazione → revisione A-team.
  CollaborationMessage sendWorkshopResult({
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: CollaborationParticipant.workshop,
      target: CollaborationParticipant.orchestrator,
      type: CollaborationMessageType.result,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Invia una revisione dell'A-team al Cantiere.
  CollaborationMessage sendReviewToWorkshop({
    required CollaborationParticipant source,
    required String content,
    String? sessionId,
    String? projectId,
    Map<String, String> metadata = const <String, String>{},
  }) {
    return _bus.send(
      source: source,
      target: CollaborationParticipant.workshop,
      type: CollaborationMessageType.review,
      content: content,
      sessionId: sessionId,
      projectId: projectId,
      metadata: metadata,
    );
  }

  /// Classifica una richiesta in modo conservativo.
  ///
  /// Per ora il comportamento è volutamente semplice.
  /// La vera classificazione semantica verrà affidata all'Orchestratore
  /// quando sarà pronto.
  CollaborationRoutingDecision classify({
    required String content,
  }) {
    final normalized = content.trim().toLowerCase();

    if (normalized.isEmpty) {
      return const CollaborationRoutingDecision(
        route: CollaborationRoute.workshop,
        reason: 'empty_request_defaults_to_workshop',
      );
    }

    if (_looksLikeCodingRequest(normalized)) {
      return const CollaborationRoutingDecision(
        route: CollaborationRoute.workshop,
        reason: 'coding_request',
      );
    }

    return const CollaborationRoutingDecision(
      route: CollaborationRoute.assistant,
      reason: 'general_request',
    );
  }

  /// Stream dei messaggi destinati al Cantiere.
  Stream<CollaborationMessage> get workshopStream =>
      _bus.messagesFor(CollaborationParticipant.workshop);

  /// Stream dei messaggi destinati all'Assistente.
  Stream<CollaborationMessage> get assistantStream =>
      _bus.messagesFor(CollaborationParticipant.assistant);

  /// Stream dei messaggi destinati all'Orchestratore.
  Stream<CollaborationMessage> get orchestratorStream =>
      _bus.messagesFor(CollaborationParticipant.orchestrator);

  bool _looksLikeCodingRequest(String value) {
    const keywords = <String>[
      'app',
      'applicazione',
      'codice',
      'programma',
      'programmare',
      'programmazione',
      'dart',
      'flutter',
      'android',
      'kotlin',
      'swift',
      'javascript',
      'typescript',
      'python',
      'github',
      'repository',
      'repo',
      'file',
      'classe',
      'funzione',
      'api',
      'bug',
      'errore',
      'build',
      'compilare',
      'compilazione',
      'test',
      'debug',
      'debuggare',
      'modifica',
      'modificare',
      'crea un app',
      'creare un app',
    ];

    return keywords.any(value.contains);
  }
}
