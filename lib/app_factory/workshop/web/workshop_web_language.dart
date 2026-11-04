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
