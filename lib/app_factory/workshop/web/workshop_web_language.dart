import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Language preferences belong to Aivexus Web, not to the native Orchestrator.
/// No project, cloud credential or cross-product setting is modified.
final class WorkshopWebLanguage extends ChangeNotifier {
  WorkshopWebLanguage({String initialCode = 'it', SharedPreferences? preferences})
      : _code = normalize(initialCode),
        _preferences = preferences;

  static const String storageKey = 'aivexus.web.ui.language.v1';
  static const List<String> codes = <String>['it', 'fr', 'en', 'es'];
  static const Map<String, String> names = <String, String>{
    'it': 'Italiano',
    'fr': 'Français',
    'en': 'English',
    'es': 'Español',
  };
  final SharedPreferences? _preferences;
  String _code;

  String get code => _code;
  Locale get locale => Locale(_code);

  static String normalize(String value) =>
      codes.contains(value.toLowerCase()) ? value.toLowerCase() : 'it';

  static Future<WorkshopWebLanguage> open() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(storageKey);
    final device = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return WorkshopWebLanguage(
      initialCode: stored ?? device,
      preferences: prefs,
    );
  }

  Future<void> select(String value) async {
    final normalized = normalize(value);
    if (normalized == _code) return;
    _code = normalized;
    notifyListeners();
    await _preferences?.setString(storageKey, _code);
  }

  String text(String source) =>
      _translations[_code]?[source] ?? source;

  String get replyLanguageName => switch (_code) {
        'fr' => 'français',
        'en' => 'English',
        'es' => 'español',
        _ => 'italiano',
      };
}

/// Rebuilds only Web surfaces that depend on the chosen language.
final class WorkshopWebLanguageScope
    extends InheritedNotifier<WorkshopWebLanguage> {
  const WorkshopWebLanguageScope({
    super.key,
    required WorkshopWebLanguage language,
    required super.child,
  }) : super(notifier: language);

  static WorkshopWebLanguage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkshopWebLanguageScope>()
          ?.notifier;

  static String tr(BuildContext context, String source) =>
      maybeOf(context)?.text(source) ?? source;
}

const Map<String, Map<String, String>> _translations = {
  'fr': {
    'Titolo': 'Titre',
    'Tipo progetto': 'Type de projet',
    'Piattaforme': 'Plateformes',
    'Completati': 'Terminés',
    'Nessun progetto in corso.': 'Aucun projet en cours.',
    'Nessun progetto completato.': 'Aucun projet terminé.',
    'Bozza': 'Brouillon',
    'Approvato': 'Approuvé',
    'Titolo progetto': 'Nom du projet',
    'Cosa deve fare?': 'Que doit faire le projet ?',
    'Descrivi il modello 3D': 'Décrivez le modèle 3D',
    'Descrivi il gioco': 'Décrivez le jeu',
    'Descrivi il comportamento e il risultato desiderato.': 'Décrivez le fonctionnement et le résultat souhaité.',
    'Descrivi forma, misure e risultato desiderato.': 'Décrivez les formes, dimensions et résultat souhaités.',
    'Descrivi regole, obiettivo e controlli desiderati.': 'Décrivez les règles, le but et les contrôles souhaités.',
    'Salvataggio in corso…': 'Enregistrement…',
    'Prepara proposta': 'Préparer une proposition',
    'Crea bozza Stampa 3D': 'Créer un brouillon 3D',
    'Crea bozza Videogioco': 'Créer un brouillon jeu vidéo',
    'App / Software': 'Application / Logiciel',
    'Stampa 3D': 'Impression 3D',
    'Videogiochi': 'Jeux vidéo',
    'Tipo non supportato': 'Type non pris en charge',
    'App e software seguono il flusso proposta → approvazione del Cantiere.': 'Les applications suivent le parcours proposition → approbation de l’Atelier.',
    'Stampa 3D salva una bozza CAD nello stesso progetto; il runner 3D arriverà nello Studio dedicato.': 'L\'impression 3D enregistre un brouillon CAO dans le projet. L\'exécuteur 3D arrivera plus tard.',
    'Videogiochi salva una bozza GameSpec nello stesso progetto; il runner gioco arriverà nello Studio dedicato.': 'Les jeux vidéo enregistrent un brouillon GameSpec. L\'exécuteur arrivera plus tard.',
    'La creazione non parte da questo pulsante. Prima vedrai la proposta e dovrai approvarla esplicitamente.': 'Ce bouton ne lance pas la création. Vous devrez d\'abord approuver la proposition.',
    'La bozza viene salvata nello stesso elenco progetti. Il runner specializzato non è ancora collegato e nessuna generazione viene simulata.': 'Le brouillon est enregistré parmi les projets. Aucun exécuteur spécialisé n\'est encore connecté.',
    'Ogni progetto ha il proprio stato. La vecchia cronologia chat globale non viene mescolata con i nuovi progetti.': 'Chaque projet conserve son propre état. L\'ancien historique de conversation n\'est pas mélangé aux nouveaux projets.',
    'Bozza salvata · runner non ancora collegato': 'Brouillon sauvegardé · exécuteur non connecté',
    'Pronto per avvio creazione': 'Prêt pour le démarrage de la création',
    'Progetto approvato': 'Projet approuvé',
    'Approvazione progetto': 'Approbation du projet',
    'Stato': 'État',
    'Cantiere': 'Atelier',
    'Lingua': 'Langue',
    'Cantiere Web': 'Atelier Web',
    'Cantiere shell': 'Interface Atelier',
    'Durable browser storage': 'Stockage persistant du navigateur',
    'Cloud / AUTO execution': 'Exécution Cloud / AUTO',
    'Module Library + Researcher': 'Bibliothèque de modules + Chercheur',
    'Diagnostics': 'Diagnostics',
    'Native local inference': 'Inférence locale native',
    'Native process execution': 'Exécution de processus natifs',
    'Available': 'Disponible',
    'Planned': 'Prévu',
    'Unavailable': 'Indisponible',
    'Nuovo progetto': 'Nouveau projet',
    'Riprova lettura': 'Réessayer le chargement',
    'Approva progetto': 'Approuver le projet',
    'Modifica progetto': 'Modifier le projet',
    'Annulla': 'Annuler',
    'Approva': 'Approuver',
    'Errore': 'Erreur',
    'Tipo': 'Type',
    'Fase': 'Phase',
    'Elemento': 'Élément',
    'Stato progetto': 'Statut',
    'Cosa deve fare': 'Fonctionnalités souhaitées',
    'Progetto in sola lettura': 'Projet en lecture seule',
    'Inizia creazione': 'Commencer la création',
    'Bozza salvata': 'Brouillon enregistré',
    'Da approvare': 'À approuver',
    'Bloccato': 'Bloqué',
    'In corso': 'En cours',
    'Completato': 'Terminé',
    'Nuovo progetto software': 'Nouveau projet logiciel',
    'Proposta del Cantiere': "Proposition de l’Atelier",
    'Domanda / chiarimento del Cantiere': "Question / précision de l’Atelier",
    'Cloud / AUTO è pronto.': 'Cloud / AUTO est prêt.',
    'Server-side AUTO routing ready for Orchestrator, Architect, Engineer and Reviewer.':
        'Routage AUTO prêt pour Orchestrator, Architect, Engineer et Reviewer.',
    'Browser-safe startup with no native or Assistant dependency.':
        "Démarrage dans le navigateur, sans dépendance à l’Assistant ni au moteur natif.",
    'Shared contracts remain the target; browser adapter comes later.':
        "Les contrats partagés sont prévus ; l’adaptateur navigateur viendra ensuite.",
    'Browser-safe queue/transport is planned; public privacy projection stays shared.':
        'Le diagnostic Web sera ajouté ultérieurement.',
    'Explicitly unavailable in W1; no llama.cpp/FFI fallback is attempted.':
        "Non disponible sur le Web ; aucun repli vers FFI n'est tenté.",
    'Explicitly unavailable in the browser.':
        'Non disponible dans le navigateur.',
    'Checking the server-side capability broker. No provider secret is stored in the browser.':
        "Vérification du broker. Aucune clé fournisseur n'est stockée dans le navigateur.",
    'Server-side broker is reachable but one or more Cantiere capabilities are not configured.':
        'Le broker répond, mais certaines capacités ne sont pas configurées.',
    'Preparazione proposta': 'Préparation de la proposition',
    'Analisi richiesta': 'Analyse de la demande',
    'Analisi non completata': 'Analyse non terminée',
    'Proposta pronta': 'Proposition prête',
    'Attende approvazione del proprietario': "En attente de l'approbation du propriétaire",
    'Chiarimento richiesto': 'Précision nécessaire',
    'Inferenza Cloud / AUTO': 'Inférence Cloud / AUTO',
  },
  'en': {
    'Titolo': 'Title',
    'Tipo progetto': 'Project type',
    'Piattaforme': 'Platforms',
    'Completati': 'Completed',
    'Nessun progetto in corso.': 'No active projects.',
    'Nessun progetto completato.': 'No completed projects.',
    'Bozza': 'Draft',
    'Approvato': 'Approved',
    'Titolo progetto': 'Project title',
    'Cosa deve fare?': 'What should it do?',
    'Descrivi il modello 3D': 'Describe the 3D model',
    'Descrivi il gioco': 'Describe the game',
    'Descrivi il comportamento e il risultato desiderato.': 'Describe the intended behavior and result.',
    'Descrivi forma, misure e risultato desiderato.': 'Describe the shape, dimensions and intended result.',
    'Descrivi regole, obiettivo e controlli desiderati.': 'Describe the rules, objective and controls.',
    'Salvataggio in corso…': 'Saving…',
    'Prepara proposta': 'Prepare proposal',
    'Crea bozza Stampa 3D': 'Create 3D draft',
    'Crea bozza Videogioco': 'Create game draft',
    'App / Software': 'App / Software',
    'Stampa 3D': '3D printing',
    'Videogiochi': 'Video games',
    'Tipo non supportato': 'Unsupported type',
    'App e software seguono il flusso proposta → approvazione del Cantiere.': 'Software follows the proposal → approval workflow.',
    'Stampa 3D salva una bozza CAD nello stesso progetto; il runner 3D arriverà nello Studio dedicato.': '3D printing saves a CAD draft; the dedicated 3D runner is planned.',
    'Videogiochi salva una bozza GameSpec nello stesso progetto; il runner gioco arriverà nello Studio dedicato.': 'Games save a GameSpec draft; the dedicated game runner is planned.',
    'La creazione non parte da questo pulsante. Prima vedrai la proposta e dovrai approvarla esplicitamente.': 'This button does not start building. You will see and approve the proposal first.',
    'La bozza viene salvata nello stesso elenco progetti. Il runner specializzato non è ancora collegato e nessuna generazione viene simulata.': 'The draft is saved in the projects list. No specialized runner is connected yet.',
    'Ogni progetto ha il proprio stato. La vecchia cronologia chat globale non viene mescolata con i nuovi progetti.': 'Each project keeps its own state. Previous global chat history is not mixed with new projects.',
    'Bozza salvata · runner non ancora collegato': 'Draft saved · runner not connected',
    'Pronto per avvio creazione': 'Ready to begin building',
    'Progetto approvato': 'Project approved',
    'Approvazione progetto': 'Project approval',
    'Stato': 'Status',
    'Cantiere': 'Workshop',
    'Lingua': 'Language',
    'Cantiere Web': 'Web Workshop',
    'Cantiere shell': 'Workshop shell',
    'Durable browser storage': 'Persistent browser storage',
    'Cloud / AUTO execution': 'Cloud / AUTO inference',
    'Module Library + Researcher': 'Module Library + Researcher',
    'Diagnostics': 'Diagnostics',
    'Native local inference': 'Native local inference',
    'Native process execution': 'Native process execution',
    'Available': 'Available',
    'Planned': 'Planned',
    'Unavailable': 'Unavailable',
    'Nuovo progetto': 'New project',
    'Riprova lettura': 'Retry loading',
    'Approva progetto': 'Approve project',
    'Modifica progetto': 'Edit project',
    'Annulla': 'Cancel',
    'Approva': 'Approve',
    'Errore': 'Error',
    'Tipo': 'Type',
    'Fase': 'Stage',
    'Elemento': 'Current item',
    'Stato progetto': 'Status',
    'Cosa deve fare': 'What should it do?',
    'Progetto in sola lettura': 'Read-only project',
    'Inizia creazione': 'Start building',
    'Bozza salvata': 'Draft saved',
    'Da approvare': 'Awaiting approval',
    'Bloccato': 'Blocked',
    'In corso': 'In progress',
    'Completato': 'Completed',
    'Nuovo progetto software': 'New software project',
    'Proposta del Cantiere': 'Workshop proposal',
    'Domanda / chiarimento del Cantiere': 'Workshop question / clarification',
    'Cloud / AUTO è pronto.': 'Cloud / AUTO is ready.',
    'Server-side AUTO routing ready for Orchestrator, Architect, Engineer and Reviewer.':
        'Server-side AUTO routing ready for Orchestrator, Architect, Engineer and Reviewer.',
    'Browser-safe startup with no native or Assistant dependency.':
        'Browser-ready without native runtime or Assistant dependency.',
    'Shared contracts remain the target; browser adapter comes later.':
        'Shared contracts are planned; the browser adapter comes later.',
    'Browser-safe queue/transport is planned; public privacy projection stays shared.':
        'Web diagnostics are planned.',
    'Explicitly unavailable in W1; no llama.cpp/FFI fallback is attempted.':
        'Unavailable in Web; no llama.cpp/FFI fallback is attempted.',
    'Explicitly unavailable in the browser.':
        'Unavailable in the browser.',
    'Checking the server-side capability broker. No provider secret is stored in the browser.':
        'Checking the broker; provider credentials remain server-side.',
    'Server-side broker is reachable but one or more Cantiere capabilities are not configured.':
        'Broker reachable; some capabilities are not configured.',
    'Preparazione proposta': 'Preparing proposal',
    'Analisi richiesta': 'Analyzing request',
    'Analisi non completata': 'Analysis incomplete',
    'Proposta pronta': 'Proposal ready',
    'Attende approvazione del proprietario': 'Awaiting owner approval',
    'Chiarimento richiesto': 'Clarification required',
    'Inferenza Cloud / AUTO': 'Cloud / AUTO inference',
  },
  'es': {
    'Titolo': 'Título',
    'Tipo progetto': 'Tipo de proyecto',
    'Piattaforme': 'Plataformas',
    'Completati': 'Terminados',
    'Nessun progetto in corso.': 'No hay proyectos activos.',
    'Nessun progetto completato.': 'No hay proyectos terminados.',
    'Bozza': 'Borrador',
    'Approvato': 'Aprobado',
    'Titolo progetto': 'Título del proyecto',
    'Cosa deve fare?': '¿Qué debe hacer?',
    'Descrivi il modello 3D': 'Describe el modelo 3D',
    'Descrivi il gioco': 'Describe el juego',
    'Descrivi il comportamento e il risultato desiderato.': 'Describe el funcionamiento y resultado deseado.',
    'Descrivi forma, misure e risultato desiderato.': 'Describe la forma, medidas y resultado deseado.',
    'Descrivi regole, obiettivo e controlli desiderati.': 'Describe las reglas, el objetivo y los controles.',
    'Salvataggio in corso…': 'Guardando…',
    'Prepara proposta': 'Preparar propuesta',
    'Crea bozza Stampa 3D': 'Crear borrador 3D',
    'Crea bozza Videogioco': 'Crear borrador de videojuego',
    'App / Software': 'App / Software',
    'Stampa 3D': 'Impresión 3D',
    'Videogiochi': 'Videojuegos',
    'Tipo non supportato': 'Tipo no compatible',
    'App e software seguono il flusso proposta → approvazione del Cantiere.': 'Las aplicaciones siguen el flujo propuesta → aprobación del Taller.',
    'Stampa 3D salva una bozza CAD nello stesso progetto; il runner 3D arriverà nello Studio dedicato.': 'La impresión 3D guarda un borrador CAD; el ejecutor 3D llegará después.',
    'Videogiochi salva una bozza GameSpec nello stesso progetto; il runner gioco arriverà nello Studio dedicato.': 'Los videojuegos guardan un borrador GameSpec; el ejecutor llegará después.',
    'La creazione non parte da questo pulsante. Prima vedrai la proposta e dovrai approvarla esplicitamente.': 'Este botón no inicia la creación. Primero revisarás y aprobarás la propuesta.',
    'La bozza viene salvata nello stesso elenco progetti. Il runner specializzato non è ancora collegato e nessuna generazione viene simulata.': 'El borrador se guarda en la lista de proyectos. El ejecutor especializado aún no está conectado.',
    'Ogni progetto ha il proprio stato. La vecchia cronologia chat globale non viene mescolata con i nuovi progetti.': 'Cada proyecto guarda su estado. El historial global anterior no se mezcla con los proyectos nuevos.',
    'Bozza salvata · runner non ancora collegato': 'Borrador guardado · ejecutor no conectado',
    'Pronto per avvio creazione': 'Listo para iniciar la creación',
    'Progetto approvato': 'Proyecto aprobado',
    'Approvazione progetto': 'Aprobación del proyecto',
    'Stato': 'Estado',
    'Cantiere': 'Taller',
    'Lingua': 'Idioma',
    'Cantiere Web': 'Taller Web',
    'Cantiere shell': 'Interfaz del Taller',
    'Durable browser storage': 'Almacenamiento persistente del navegador',
    'Cloud / AUTO execution': 'Inferencia Cloud / AUTO',
    'Module Library + Researcher': 'Biblioteca de módulos + Investigador',
    'Diagnostics': 'Diagnósticos',
    'Native local inference': 'Inferencia local nativa',
    'Native process execution': 'Ejecución de procesos nativos',
    'Available': 'Disponible',
    'Planned': 'Previsto',
    'Unavailable': 'No disponible',
    'Nuovo progetto': 'Nuevo proyecto',
    'Riprova lettura': 'Reintentar carga',
    'Approva progetto': 'Aprobar proyecto',
    'Modifica progetto': 'Editar proyecto',
    'Annulla': 'Cancelar',
    'Approva': 'Aprobar',
    'Errore': 'Error',
    'Tipo': 'Tipo',
    'Fase': 'Fase',
    'Elemento': 'Elemento',
    'Stato progetto': 'Estado',
    'Cosa deve fare': 'Qué debe hacer',
    'Progetto in sola lettura': 'Proyecto de solo lectura',
    'Inizia creazione': 'Iniciar construcción',
    'Bozza salvata': 'Borrador guardado',
    'Da approvare': 'Pendiente de aprobación',
    'Bloccato': 'Bloqueado',
    'In corso': 'En curso',
    'Completato': 'Completado',
    'Nuovo progetto software': 'Nuevo proyecto de software',
    'Proposta del Cantiere': 'Propuesta del Taller',
    'Domanda / chiarimento del Cantiere': 'Pregunta / aclaración del Taller',
    'Cloud / AUTO è pronto.': 'Cloud / AUTO está listo.',
    'Server-side AUTO routing ready for Orchestrator, Architect, Engineer and Reviewer.':
        'Rutas AUTO listas para Orchestrator, Architect, Engineer y Reviewer.',
    'Browser-safe startup with no native or Assistant dependency.':
        'Inicio Web sin depender del Asistente ni del entorno nativo.',
    'Shared contracts remain the target; browser adapter comes later.':
        'Los contratos compartidos están previstos; el adaptador llegará después.',
    'Browser-safe queue/transport is planned; public privacy projection stays shared.':
        'Los diagnósticos Web se añadirán más adelante.',
    'Explicitly unavailable in W1; no llama.cpp/FFI fallback is attempted.':
        'No disponible en Web; sin alternativa mediante FFI.',
    'Explicitly unavailable in the browser.':
        'No disponible en el navegador.',
    'Checking the server-side capability broker. No provider secret is stored in the browser.':
        'Comprobando el broker; las credenciales siguen en el servidor.',
    'Server-side broker is reachable but one or more Cantiere capabilities are not configured.':
        'El broker responde, pero faltan algunas capacidades.',
    'Preparazione proposta': 'Preparando propuesta',
    'Analisi richiesta': 'Análisis de solicitud',
    'Analisi non completata': 'Análisis incompleto',
    'Proposta pronta': 'Propuesta lista',
    'Attende approvazione del proprietario': 'Pendiente de aprobación',
    'Chiarimento richiesto': 'Se necesita aclaración',
    'Inferenza Cloud / AUTO': 'Inferencia Cloud / AUTO',
  }
};
