import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

/// Canonical capability identifiers shared conceptually with the external
/// AI-Orchestrator Module Library.
///
/// This file deliberately does not import or contact the Library. The future
/// bridge validates these identifiers/contracts against an offline or remote
/// Library snapshot. Keeping this stage pure prevents network availability
/// from becoming a prerequisite for project planning.
abstract final class WorkshopLibraryCapabilityIds {
  static const String authSession = 'auth.session';
  static const String storageSecrets = 'storage.secrets';
  static const String networkHttp = 'network.http';
  static const String storageLocalDb = 'storage.local_db';
  static const String diagnosticsLogging = 'diagnostics.logging';
  static const String releaseUpdateManager = 'release.update_manager';
  static const String aiLocalInference = 'ai.local_inference';
  static const String voiceStt = 'voice.stt';
  static const String voiceTts = 'voice.tts';
}

/// Explicit proof that the project plan has crossed its owner/architecture
/// approval boundary before reusable capabilities are selected.
///
/// The current Workshop lifecycle does not yet persist a project-level
/// approval object, so this evidence is intentionally passed into the pure
/// shopping-list builder. The later production integration will create this
/// object at the real approval boundary rather than making the builder guess.
final class WorkshopProjectApprovalEvidence {
  const WorkshopProjectApprovalEvidence({
    required this.projectId,
    required this.approvalId,
    required this.approvedAt,
    required this.approvedBy,
  });

  final String projectId;
  final String approvalId;
  final DateTime approvedAt;
  final String approvedBy;

  Map<String, Object?> toJson() => <String, Object?>{
        'projectId': projectId,
        'approvalId': approvalId,
        'approvedAt': approvedAt.toUtc().toIso8601String(),
        'approvedBy': approvedBy,
      };
}

enum WorkshopCapabilityEvidenceSource {
  goal,
  requirement,
  constraint,
  technology,
  hardware,
  deliverable,
  validationCriterion,
  phase,
  task,
}

final class WorkshopCapabilityEvidence {
  const WorkshopCapabilityEvidence({
    required this.source,
    required this.text,
    required this.priority,
  });

  final WorkshopCapabilityEvidenceSource source;
  final String text;
  final WorkshopProjectPriority priority;

  Map<String, Object?> toJson() => <String, Object?>{
        'source': source.name,
        'text': text,
        'priority': priority.name,
      };
}

/// One item in the Cantiere's project-level "shopping list".
///
/// A shopping item describes a capability need, not a concrete module. The
/// future Library bridge can therefore compare multiple interchangeable Lego
/// implementations without coupling the project plan to a vendor/engine.
final class WorkshopCapabilityNeed {
  const WorkshopCapabilityNeed({
    required this.capabilityId,
    required this.preferredContractId,
    required this.priority,
    required this.required,
    required this.targets,
    required this.evidence,
  });

  final String capabilityId;
  final String preferredContractId;
  final WorkshopProjectPriority priority;
  final bool required;
  final List<String> targets;
  final List<WorkshopCapabilityEvidence> evidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'capabilityId': capabilityId,
        'preferredContractId': preferredContractId,
        'priority': priority.name,
        'required': required,
        'targets': targets,
        'evidence': evidence.map((item) => item.toJson()).toList(growable: false),
      };
}

final class WorkshopCapabilityShoppingList {
  const WorkshopCapabilityShoppingList({
    required this.projectId,
    required this.generatedAt,
    required this.approval,
    required this.targets,
    required this.needs,
    required this.unmappedInputs,
  });

  final String projectId;
  final DateTime generatedAt;
  final WorkshopProjectApprovalEvidence approval;
  final List<String> targets;
  final List<WorkshopCapabilityNeed> needs;

  /// Plan statements that intentionally were not converted into a capability.
  ///
  /// Preserving them avoids pretending that keyword extraction understood the
  /// entire architecture. A later Architect pass can turn these into explicit
  /// capability requirements without losing the original signal.
  final List<String> unmappedInputs;

  bool get isEmpty => needs.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'projectId': projectId,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'approval': approval.toJson(),
        'targets': targets,
        'needs': needs.map((item) => item.toJson()).toList(growable: false),
        'unmappedInputs': unmappedInputs,
      };
}

final class WorkshopCapabilityRule {
  const WorkshopCapabilityRule({
    required this.capabilityId,
    required this.contractId,
    required this.keywords,
  });

  final String capabilityId;
  final String contractId;
  final List<String> keywords;
}

/// Pure, deterministic adapter from an approved Workshop project plan to the
/// capability shopping list that will later be resolved against the external
/// Module Library.
///
/// No LLM, network, file-system or Library dependency is used here.
final class WorkshopCapabilityShoppingListBuilder {
  const WorkshopCapabilityShoppingListBuilder({
    this.rules = defaultRules,
  });

  final List<WorkshopCapabilityRule> rules;

  static const List<WorkshopCapabilityRule> defaultRules =
      <WorkshopCapabilityRule>[
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.authSession,
      contractId: 'auth.session.v1',
      keywords: <String>[
        'auth',
        'authentication',
        'login',
        'sign in',
        'session management',
        'user session',
        'autenticazione',
        'accesso utente',
        'sessione utente',
        'connexion utilisateur',
        'sesion de usuario',
        'sesión de usuario',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.storageSecrets,
      contractId: 'storage.secrets.v1',
      keywords: <String>[
        'secure storage',
        'secret storage',
        'secrets',
        'keychain',
        'keystore',
        'credentials',
        'api key',
        'token storage',
        'archiviazione sicura',
        'credenziali',
        'chiavi api',
        'stockage securise',
        'stockage sécurisé',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.networkHttp,
      contractId: 'network.http.v1',
      keywords: <String>[
        'http',
        'api client',
        'rest api',
        'network request',
        'web api',
        'client api',
        'richiesta api',
        'chiamata api',
        'client http',
        'requete http',
        'requête http',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.storageLocalDb,
      contractId: 'storage.local_db.v1',
      keywords: <String>[
        'sqlite',
        'local database',
        'database locale',
        'local db',
        'persistence',
        'persistenza',
        'offline database',
        'base de donnees locale',
        'base de données locale',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.diagnosticsLogging,
      contractId: 'diagnostics.logging.v1',
      keywords: <String>[
        'logging',
        'structured log',
        'diagnostics',
        'diagnostic logs',
        'crash logs',
        'log strutturati',
        'diagnostica',
        'journalisation',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.releaseUpdateManager,
      contractId: 'release.update_manager.v1',
      keywords: <String>[
        'update manager',
        'auto update',
        'automatic update',
        'updater',
        'download manager',
        'ota update',
        'aggiornamento automatico',
        'gestore download',
        'mise a jour automatique',
        'mise à jour automatique',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.aiLocalInference,
      contractId: 'ai.local_inference.v1',
      keywords: <String>[
        'local inference',
        'local llm',
        'llm locale',
        'llama cpp',
        'llama.cpp',
        'gguf',
        'inferenza locale',
        'inference locale',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.voiceStt,
      contractId: 'voice.stt.v1',
      keywords: <String>[
        'stt',
        'speech to text',
        'speech recognition',
        'voice input',
        'transcription',
        'voice assistant',
        'riconoscimento vocale',
        'trascrizione',
        'assistente vocale',
        'reconnaissance vocale',
      ],
    ),
    WorkshopCapabilityRule(
      capabilityId: WorkshopLibraryCapabilityIds.voiceTts,
      contractId: 'voice.tts.v1',
      keywords: <String>[
        'tts',
        'text to speech',
        'speech synthesis',
        'voice output',
        'voice assistant',
        'sintesi vocale',
        'assistente vocale',
        'synthese vocale',
        'synthèse vocale',
      ],
    ),
  ];

  WorkshopCapabilityShoppingList build({
    required WorkshopProjectPlan plan,
    required WorkshopProjectApprovalEvidence approval,
  }) {
    _validateApproval(plan, approval);

    final targets = _inferTargets(plan);
    final signals = _collectSignals(plan);
    final matches = <String, _MutableCapabilityNeed>{};
    final matchedSignalIndexes = <int>{};

    for (var signalIndex = 0; signalIndex < signals.length; signalIndex++) {
      final signal = signals[signalIndex];
      for (final rule in rules) {
        if (!_matchesAny(signal.text, rule.keywords)) {
          continue;
        }
        matchedSignalIndexes.add(signalIndex);
        final need = matches.putIfAbsent(
          rule.capabilityId,
          () => _MutableCapabilityNeed(
            capabilityId: rule.capabilityId,
            preferredContractId: rule.contractId,
          ),
        );
        need.addEvidence(signal);
      }
    }

    final needs = matches.values
        .map(
          (item) => item.freeze(targets),
        )
        .toList(growable: false)
      ..sort((left, right) => left.capabilityId.compareTo(right.capabilityId));

    final unmapped = <String>[];
    final seenUnmapped = <String>{};
    for (var index = 0; index < signals.length; index++) {
      if (matchedSignalIndexes.contains(index)) {
        continue;
      }
      final text = signals[index].text.trim();
      if (text.isEmpty || !seenUnmapped.add(text)) {
        continue;
      }
      unmapped.add(text);
    }

    return WorkshopCapabilityShoppingList(
      projectId: plan.id,
      generatedAt: approval.approvedAt,
      approval: approval,
      targets: targets,
      needs: needs,
      unmappedInputs: List.unmodifiable(unmapped),
    );
  }

  void _validateApproval(
    WorkshopProjectPlan plan,
    WorkshopProjectApprovalEvidence approval,
  ) {
    if (plan.status == WorkshopProjectStatus.draft ||
        plan.status == WorkshopProjectStatus.cancelled) {
      throw StateError(
        'Capability shopping list requires a planned/approved project.',
      );
    }
    if (approval.projectId.trim().isEmpty || approval.projectId != plan.id) {
      throw StateError(
        'Project approval does not belong to ${plan.id}.',
      );
    }
    if (approval.approvalId.trim().isEmpty || approval.approvedBy.trim().isEmpty) {
      throw StateError('Project approval evidence is incomplete.');
    }
  }

  List<String> _inferTargets(WorkshopProjectPlan plan) {
    final text = <String>[
      plan.goal,
      ...plan.requirements,
      ...plan.constraints,
      ...plan.technologies,
      ...plan.hardware,
      ...plan.deliverables,
      ...plan.tasks.map((task) => task.description),
    ].join(' ');
    final normalized = _normalize(text);
    final targets = <String>{};

    void addIf(String target, List<String> terms) {
      if (terms.any((term) => _containsPhrase(normalized, _normalize(term)))) {
        targets.add(target);
      }
    }

    addIf('android', <String>['android']);
    addIf('ios', <String>['ios', 'iphone', 'ipad']);
    addIf('windows', <String>['windows']);
    addIf('macos', <String>['macos', 'mac os']);
    addIf('linux', <String>['linux']);
    addIf('web', <String>['web', 'browser', 'pwa']);
    addIf('raspberry_pi', <String>['raspberry pi', 'raspberry']);
    addIf('embedded', <String>['embedded', 'microcontroller', 'microcontrollore']);

    final sorted = targets.toList(growable: false)..sort();
    return List.unmodifiable(sorted);
  }

  List<WorkshopCapabilityEvidence> _collectSignals(WorkshopProjectPlan plan) {
    final result = <WorkshopCapabilityEvidence>[];

    void add(
      WorkshopCapabilityEvidenceSource source,
      String text,
      WorkshopProjectPriority priority,
    ) {
      final value = text.trim();
      if (value.isEmpty) {
        return;
      }
      result.add(
        WorkshopCapabilityEvidence(
          source: source,
          text: value,
          priority: priority,
        ),
      );
    }

    add(
      WorkshopCapabilityEvidenceSource.goal,
      plan.goal,
      WorkshopProjectPriority.normal,
    );
    for (final value in plan.requirements) {
      add(
        WorkshopCapabilityEvidenceSource.requirement,
        value,
        WorkshopProjectPriority.high,
      );
    }
    for (final value in plan.constraints) {
      add(
        WorkshopCapabilityEvidenceSource.constraint,
        value,
        WorkshopProjectPriority.high,
      );
    }
    for (final value in plan.technologies) {
      add(
        WorkshopCapabilityEvidenceSource.technology,
        value,
        WorkshopProjectPriority.normal,
      );
    }
    for (final value in plan.hardware) {
      add(
        WorkshopCapabilityEvidenceSource.hardware,
        value,
        WorkshopProjectPriority.normal,
      );
    }
    for (final value in plan.deliverables) {
      add(
        WorkshopCapabilityEvidenceSource.deliverable,
        value,
        WorkshopProjectPriority.normal,
      );
    }
    for (final value in plan.validationCriteria) {
      add(
        WorkshopCapabilityEvidenceSource.validationCriterion,
        value,
        WorkshopProjectPriority.normal,
      );
    }
    for (final phase in plan.phases) {
      add(
        WorkshopCapabilityEvidenceSource.phase,
        '${phase.title} ${phase.description}',
        phase.priority,
      );
    }
    for (final task in plan.tasks) {
      add(
        WorkshopCapabilityEvidenceSource.task,
        '${task.title} ${task.description}',
        task.priority,
      );
    }
    return result;
  }

  bool _matchesAny(String text, List<String> keywords) {
    final normalized = _normalize(text);
    return keywords.any(
      (keyword) => _containsPhrase(normalized, _normalize(keyword)),
    );
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9à-ÿ._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _containsPhrase(String normalizedText, String normalizedPhrase) {
    if (normalizedText.isEmpty || normalizedPhrase.isEmpty) {
      return false;
    }
    return ' $normalizedText '.contains(' $normalizedPhrase ');
  }
}

final class _MutableCapabilityNeed {
  _MutableCapabilityNeed({
    required this.capabilityId,
    required this.preferredContractId,
  });

  final String capabilityId;
  final String preferredContractId;
  final List<WorkshopCapabilityEvidence> evidence =
      <WorkshopCapabilityEvidence>[];

  void addEvidence(WorkshopCapabilityEvidence item) {
    if (evidence.any(
      (existing) =>
          existing.source == item.source && existing.text == item.text,
    )) {
      return;
    }
    evidence.add(item);
  }

  WorkshopCapabilityNeed freeze(List<String> targets) {
    var priority = WorkshopProjectPriority.low;
    var required = false;
    for (final item in evidence) {
      if (_priorityWeight(item.priority) > _priorityWeight(priority)) {
        priority = item.priority;
      }
      if (item.source == WorkshopCapabilityEvidenceSource.goal ||
          item.source == WorkshopCapabilityEvidenceSource.requirement ||
          item.source == WorkshopCapabilityEvidenceSource.constraint) {
        required = true;
      }
    }

    return WorkshopCapabilityNeed(
      capabilityId: capabilityId,
      preferredContractId: preferredContractId,
      priority: priority,
      required: required,
      targets: targets,
      evidence: List.unmodifiable(evidence),
    );
  }

  static int _priorityWeight(WorkshopProjectPriority value) {
    switch (value) {
      case WorkshopProjectPriority.low:
        return 0;
      case WorkshopProjectPriority.normal:
        return 1;
      case WorkshopProjectPriority.high:
        return 2;
      case WorkshopProjectPriority.critical:
        return 3;
    }
  }
}
