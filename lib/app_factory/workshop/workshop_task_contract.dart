import 'workshop_contract.dart';

/// Risorsa che può essere utilizzata per eseguire una task del Cantiere.
///
/// Local:
///   strumenti disponibili direttamente sul dispositivo.
///
/// Github Agent:
///   agente autonomo che lavora sul repository.
///
/// Github Actions:
///   infrastruttura remota per build, test e workflow.
///
/// Hybrid AI:
///   collaborazione tra più provider AI, ad esempio OpenAI, Gemini,
///   Claude o altri provider configurati.
///
/// Cloud:
///   esecuzione completamente remota.
enum WorkshopTaskResource {
  local,
  githubAgent,
  githubActions,
  hybridAi,
  cloud,
}

/// Modalità operativa richiesta per una task.
enum WorkshopTaskMode {
  local,
  github,
  hybrid,
  cloud,
}

/// Stato della task.
enum WorkshopTaskStatus {
  planned,
  ready,
  reserved,
  running,
  checkpointed,
  waitingApproval,
  completed,
  failed,
  cancelled,
}

/// Tipo di lavoro svolto dalla task.
enum WorkshopTaskKind {
  analysis,
  planning,
  codeGeneration,
  codeModification,
  test,
  lint,
  build,
  debugging,
  documentation,
  review,
  integration,
}

/// Priorità della task.
enum WorkshopTaskPriority {
  low,
  normal,
  high,
  critical,
}

/// Criterio verificabile che deve essere soddisfatto
/// prima di considerare completata una task.
final class WorkshopTaskAcceptanceCriterion {
  const WorkshopTaskAcceptanceCriterion({
    required this.id,
    required this.description,
    this.required = true,
  });

  final String id;
  final String description;
  final bool required;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'description': description,
      'required': required,
    };
  }

  factory WorkshopTaskAcceptanceCriterion.fromJson(
    Map<String, dynamic> json,
  ) {
    return WorkshopTaskAcceptanceCriterion(
      id: json['id']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      required: json['required'] is bool
          ? json['required'] as bool
          : true,
    );
  }
}

/// File che la task può creare o modificare.
final class WorkshopTaskFileScope {
  const WorkshopTaskFileScope({
    this.allowed = const <String>[],
    this.forbidden = const <String>[],
    this.readOnly = const <String>[],
  });

  /// File che possono essere modificati.
  final List<String> allowed;

  /// File che non devono essere modificati dalla task.
  final List<String> forbidden;

  /// File che possono essere letti ma non modificati.
  final List<String> readOnly;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'allowed': allowed,
      'forbidden': forbidden,
      'readOnly': readOnly,
    };
  }

  factory WorkshopTaskFileScope.fromJson(
    Map<String, dynamic> json,
  ) {
    List<String> readList(String key) {
      final value = json[key];

      if (value is! List) {
        return const <String>[];
      }

      return List.unmodifiable(
        value
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty),
      );
    }

    return WorkshopTaskFileScope(
      allowed: readList('allowed'),
      forbidden: readList('forbidden'),
      readOnly: readList('readOnly'),
    );
  }
}

/// Budget associato all'utilizzo di una risorsa.
///
/// Non rappresenta necessariamente dollari/euro.
/// È un limite astratto che può essere mappato successivamente
/// ai crediti effettivi del provider.
final class WorkshopTaskBudget {
  const WorkshopTaskBudget({
    this.maxCredits = 0,
    this.reservedCredits = 0,
    this.minimumReserveCredits = 0,
    this.estimatedCredits = 0,
    this.allowOverrun = false,
  });

  /// Budget massimo autorizzato per la task.
  final double maxCredits;

  /// Credito già riservato prima dell'avvio.
  final double reservedCredits;

  /// Quantità che il Cantiere deve lasciare inutilizzata
  /// come margine di sicurezza.
  final double minimumReserveCredits;

  /// Stima preliminare del consumo.
  final double estimatedCredits;

  /// Se false, il Cantiere non deve superare maxCredits.
  final bool allowOverrun;

  double get availableCredits {
    final value = maxCredits - reservedCredits;

    return value < 0 ? 0 : value;
  }

  bool canStart({
    double? estimatedCost,
  }) {
    final cost = estimatedCost ?? estimatedCredits;

    return cost + minimumReserveCredits <= availableCredits;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'maxCredits': maxCredits,
      'reservedCredits': reservedCredits,
      'minimumReserveCredits': minimumReserveCredits,
      'estimatedCredits': estimatedCredits,
      'allowOverrun': allowOverrun,
    };
  }

  factory WorkshopTaskBudget.fromJson(
    Map<String, dynamic> json,
  ) {
    double number(String key) {
      final value = json[key];

      if (value is num) {
        return value.toDouble();
      }

      return 0;
    }

    return WorkshopTaskBudget(
      maxCredits: number('maxCredits'),
      reservedCredits: number('reservedCredits'),
      minimumReserveCredits: number('minimumReserveCredits'),
      estimatedCredits: number('estimatedCredits'),
      allowOverrun: json['allowOverrun'] is bool
          ? json['allowOverrun'] as bool
          : false,
    );
  }
}

/// Checkpoint persistente della task.
///
/// Il checkpoint permette di riprendere il lavoro senza
/// considerare persa l'intera task in caso di:
/// - crash;
/// - kill del processo;
/// - perdita di rete;
/// - esaurimento crediti;
/// - interruzione manuale.
final class WorkshopTaskCheckpoint {
  const WorkshopTaskCheckpoint({
    required this.id,
    required this.createdAt,
    required this.phase,
    this.completedSteps = const <String>[],
    this.changedFiles = const <String>[],
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final DateTime createdAt;
  final String phase;
  final List<String> completedSteps;
  final List<String> changedFiles;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'phase': phase,
      'completedSteps': completedSteps,
      'changedFiles': changedFiles,
      'metadata': metadata,
    };
  }

  factory WorkshopTaskCheckpoint.fromJson(
    Map<String, dynamic> json,
  ) {
    List<String> strings(String key) {
      final value = json[key];

      if (value is! List) {
        return const <String>[];
      }

      return List.unmodifiable(
        value.map((item) => item.toString()),
      );
    }

    return WorkshopTaskCheckpoint(
      id: json['id']?.toString() ?? '',
      createdAt: DateTime.tryParse(
            json['createdAt']?.toString() ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(
            0,
            isUtc: true,
          ),
      phase: json['phase']?.toString() ?? '',
      completedSteps: strings('completedSteps'),
      changedFiles: strings('changedFiles'),
      metadata: json['metadata'] is Map
          ? Map.unmodifiable(
              Map<String, dynamic>.from(
                json['metadata'] as Map,
              ),
            )
          : const <String, dynamic>{},
    );
  }
}

/// Contratto completo di una singola unità di lavoro.
///
/// Questo oggetto NON esegue la task.
///
/// Descrive:
/// - cosa deve essere fatto;
/// - cosa può essere modificato;
/// - quale risorsa è preferita;
/// - quale modalità è richiesta;
/// - quanto budget può essere consumato;
/// - quali checkpoint devono essere prodotti;
/// - quali criteri determinano il completamento.
///
/// Questo permette al Cantiere di utilizzare Local, GitHub Agent,
/// GitHub Actions oppure modalità Hybrid senza legare il contratto
/// a uno specifico provider.
final class WorkshopTaskContract {
  WorkshopTaskContract({
    required this.id,
    required this.title,
    required this.objective,
    required this.kind,
    this.mode = WorkshopTaskMode.local,
    this.preferredResource = WorkshopTaskResource.local,
    this.fallbackResources =
        const <WorkshopTaskResource>[],
    this.priority = WorkshopTaskPriority.normal,
    this.status = WorkshopTaskStatus.planned,
    this.instructions = const <String>[],
    this.constraints = const <String>[],
    this.acceptanceCriteria =
        const <WorkshopTaskAcceptanceCriterion>[],
    this.fileScope = const WorkshopTaskFileScope(),
    this.budget = const WorkshopTaskBudget(),
    this.requiredCheckpoints = const <String>[],
    this.checkpoint,
    this.parentTaskId,
    this.dependsOn = const <String>[],
    this.tags = const <String>[],
    this.metadata = const <String, dynamic>{},
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id;
  final String title;
  final String objective;

  final WorkshopTaskKind kind;

  /// Modalità operativa richiesta.
  final WorkshopTaskMode mode;

  /// Risorsa preferita dal Cantiere.
  final WorkshopTaskResource preferredResource;

  /// Risorse alternative utilizzabili se la preferita
  /// non è disponibile o non ha budget sufficiente.
  final List<WorkshopTaskResource> fallbackResources;

  final WorkshopTaskPriority priority;

  WorkshopTaskStatus status;

  /// Istruzioni precise per l'esecutore.
  final List<String> instructions;

  /// Vincoli che l'esecutore deve rispettare.
  final List<String> constraints;

  /// Criteri verificabili di completamento.
  final List<WorkshopTaskAcceptanceCriterion> acceptanceCriteria;

  /// Limiti sui file.
  final WorkshopTaskFileScope fileScope;

  /// Budget e protezione dei crediti.
  final WorkshopTaskBudget budget;

  /// Identificativi dei checkpoint richiesti.
  final List<String> requiredCheckpoints;

  /// Ultimo checkpoint verificato.
  WorkshopTaskCheckpoint? checkpoint;

  /// Task superiore da cui questa task deriva.
  final String? parentTaskId;

  /// Task che devono essere completate prima di questa.
  final List<String> dependsOn;

  final List<String> tags;

  final Map<String, dynamic> metadata;

  final DateTime createdAt;
  DateTime updatedAt;

  bool get isTerminal {
    return status == WorkshopTaskStatus.completed ||
        status == WorkshopTaskStatus.failed ||
        status == WorkshopTaskStatus.cancelled;
  }

  bool get isGithubAgentTask {
    return preferredResource ==
        WorkshopTaskResource.githubAgent;
  }

  bool get canUseHybridAi {
    return mode == WorkshopTaskMode.hybrid ||
        preferredResource == WorkshopTaskResource.hybridAi ||
        fallbackResources.contains(
          WorkshopTaskResource.hybridAi,
        );
  }

  bool get requiresGithub {
    return preferredResource ==
            WorkshopTaskResource.githubAgent ||
        preferredResource ==
            WorkshopTaskResource.githubActions ||
        fallbackResources.contains(
          WorkshopTaskResource.githubAgent,
        ) ||
        fallbackResources.contains(
          WorkshopTaskResource.githubActions,
        );
  }

  /// Indica se la task è progettata per poter essere
  /// eseguita senza consumare crediti cloud.
  bool get prefersLocal {
    return preferredResource ==
        WorkshopTaskResource.local;
  }

  /// Verifica se la task ha una specifica sufficiente
  /// per essere inviata a un agente autonomo.
  ///
  /// Non garantisce che l'Agent la completi.
  bool get isAgentReady {
    if (objective.trim().isEmpty) {
      return false;
    }

    if (instructions.isEmpty) {
      return false;
    }

    if (acceptanceCriteria.isEmpty) {
      return false;
    }

    if (fileScope.allowed.isEmpty &&
        kind != WorkshopTaskKind.analysis &&
        kind != WorkshopTaskKind.planning) {
      return false;
    }

    return true;
  }

  /// Verifica preventiva del budget.
  bool hasSafeBudget({
    double? estimatedCost,
  }) {
    return budget.canStart(
      estimatedCost: estimatedCost,
    );
  }

  void markReady() {
    if (isTerminal) {
      return;
    }

    status = WorkshopTaskStatus.ready;
    updatedAt = DateTime.now().toUtc();
  }

  void markReserved() {
    if (isTerminal) {
      return;
    }

    status = WorkshopTaskStatus.reserved;
    updatedAt = DateTime.now().toUtc();
  }

  void markRunning() {
    if (isTerminal) {
      return;
    }

    status = WorkshopTaskStatus.running;
    updatedAt = DateTime.now().toUtc();
  }

  void markCheckpointed(
    WorkshopTaskCheckpoint value,
  ) {
    if (isTerminal) {
      return;
    }

    checkpoint = value;
    status = WorkshopTaskStatus.checkpointed;
    updatedAt = DateTime.now().toUtc();
  }

  void waitForApproval() {
    if (isTerminal) {
      return;
    }

    status = WorkshopTaskStatus.waitingApproval;
    updatedAt = DateTime.now().toUtc();
  }

  void complete() {
    status = WorkshopTaskStatus.completed;
    updatedAt = DateTime.now().toUtc();
  }

  void fail() {
    status = WorkshopTaskStatus.failed;
    updatedAt = DateTime.now().toUtc();
  }

  void cancel() {
    status = WorkshopTaskStatus.cancelled;
    updatedAt = DateTime.now().toUtc();
  }

  WorkshopTaskContract copyWith({
    String? id,
    String? title,
    String? objective,
    WorkshopTaskKind? kind,
    WorkshopTaskMode? mode,
    WorkshopTaskResource? preferredResource,
    List<WorkshopTaskResource>? fallbackResources,
    WorkshopTaskPriority? priority,
    WorkshopTaskStatus? status,
    List<String>? instructions,
    List<String>? constraints,
    List<WorkshopTaskAcceptanceCriterion>?
        acceptanceCriteria,
    WorkshopTaskFileScope? fileScope,
    WorkshopTaskBudget? budget,
    List<String>? requiredCheckpoints,
    WorkshopTaskCheckpoint? checkpoint,
    String? parentTaskId,
    List<String>? dependsOn,
    List<String>? tags,
    Map<String, dynamic>? metadata,
  }) {
    return WorkshopTaskContract(
      id: id ?? this.id,
      title: title ?? this.title,
      objective: objective ?? this.objective,
      kind: kind ?? this.kind,
      mode: mode ?? this.mode,
      preferredResource:
          preferredResource ?? this.preferredResource,
      fallbackResources:
          fallbackResources ?? this.fallbackResources,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      instructions: instructions ?? this.instructions,
      constraints: constraints ?? this.constraints,
      acceptanceCriteria:
          acceptanceCriteria ?? this.acceptanceCriteria,
      fileScope: fileScope ?? this.fileScope,
      budget: budget ?? this.budget,
      requiredCheckpoints:
          requiredCheckpoints ?? this.requiredCheckpoints,
      checkpoint: checkpoint ?? this.checkpoint,
      parentTaskId:
          parentTaskId ?? this.parentTaskId,
      dependsOn: dependsOn ?? this.dependsOn,
      tags: tags ?? this.tags,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'objective': objective,
      'kind': kind.name,
      'mode': mode.name,
      'preferredResource': preferredResource.name,
      'fallbackResources': fallbackResources
          .map((resource) => resource.name)
          .toList(growable: false),
      'priority': priority.name,
      'status': status.name,
      'instructions': instructions,
      'constraints': constraints,
      'acceptanceCriteria': acceptanceCriteria
          .map((criterion) => criterion.toJson())
          .toList(growable: false),
      'fileScope': fileScope.toJson(),
      'budget': budget.toJson(),
      'requiredCheckpoints': requiredCheckpoints,
      'checkpoint': checkpoint?.toJson(),
      'parentTaskId': parentTaskId,
      'dependsOn': dependsOn,
      'tags': tags,
      'metadata': metadata,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory WorkshopTaskContract.fromJson(
    Map<String, dynamic> json,
  ) {
    WorkshopTaskKind parseKind() {
      final value = json['kind']?.toString();

      return WorkshopTaskKind.values.firstWhere(
        (item) => item.name == value,
        orElse: () => WorkshopTaskKind.codeGeneration,
      );
    }

    WorkshopTaskMode parseMode() {
      final value = json['mode']?.toString();

      return WorkshopTaskMode.values.firstWhere(
        (item) => item.name == value,
        orElse: () => WorkshopTaskMode.local,
      );
    }

    WorkshopTaskResource parseResource() {
      final value = json['preferredResource']?.toString();

      return WorkshopTaskResource.values.firstWhere(
        (item) => item.name == value,
        orElse: () => WorkshopTaskResource.local,
      );
    }

    WorkshopTaskPriority parsePriority() {
      final value = json['priority']?.toString();

      return WorkshopTaskPriority.values.firstWhere(
        (item) => item.name == value,
        orElse: () => WorkshopTaskPriority.normal,
      );
    }

    WorkshopTaskStatus parseStatus() {
      final value = json['status']?.toString();

      return WorkshopTaskStatus.values.firstWhere(
        (item) => item.name == value,
        orElse: () => WorkshopTaskStatus.planned,
      );
    }

    List<WorkshopTaskResource> parseFallbacks() {
      final value = json['fallbackResources'];

      if (value is! List) {
        return const <WorkshopTaskResource>[];
      }

      return List.unmodifiable(
        value.map(
          (item) {
            final name = item.toString();

            return WorkshopTaskResource.values.firstWhere(
              (resource) => resource.name == name,
              orElse: () =>
                  WorkshopTaskResource.local,
            );
          },
        ),
      );
    }

    List<String> parseStrings(String key) {
      final value = json[key];

      if (value is! List) {
        return const <String>[];
      }

      return List.unmodifiable(
        value.map((item) => item.toString()),
      );
    }

    List<WorkshopTaskAcceptanceCriterion>
        parseCriteria() {
      final value = json['acceptanceCriteria'];

      if (value is! List) {
        return const <
            WorkshopTaskAcceptanceCriterion>[];
      }

      return List.unmodifiable(
        value.whereType<Map>().map(
          (item) =>
              WorkshopTaskAcceptanceCriterion.fromJson(
            Map<String, dynamic>.from(item),
          ),
        ),
      );
    }

    final rawFileScope = json['fileScope'];
    final rawBudget = json['budget'];
    final rawCheckpoint = json['checkpoint'];

    return WorkshopTaskContract(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      objective: json['objective']?.toString() ?? '',
      kind: parseKind(),
      mode: parseMode(),
      preferredResource: parseResource(),
      fallbackResources: parseFallbacks(),
      priority: parsePriority(),
      status: parseStatus(),
      instructions: parseStrings('instructions'),
      constraints: parseStrings('constraints'),
      acceptanceCriteria: parseCriteria(),
      fileScope: rawFileScope is Map
          ? WorkshopTaskFileScope.fromJson(
              Map<String, dynamic>.from(rawFileScope),
            )
          : const WorkshopTaskFileScope(),
      budget: rawBudget is Map
          ? WorkshopTaskBudget.fromJson(
              Map<String, dynamic>.from(rawBudget),
            )
          : const WorkshopTaskBudget(),
      requiredCheckpoints:
          parseStrings('requiredCheckpoints'),
      checkpoint: rawCheckpoint is Map
          ? WorkshopTaskCheckpoint.fromJson(
              Map<String, dynamic>.from(
                rawCheckpoint,
              ),
            )
          : null,
      parentTaskId:
          json['parentTaskId']?.toString(),
      dependsOn: parseStrings('dependsOn'),
      tags: parseStrings('tags'),
      metadata: json['metadata'] is Map
          ? Map.unmodifiable(
              Map<String, dynamic>.from(
                json['metadata'] as Map,
              ),
            )
          : const <String, dynamic>{},
      createdAt: DateTime.tryParse(
        json['createdAt']?.toString() ?? '',
      ),
      updatedAt: DateTime.tryParse(
        json['updatedAt']?.toString() ?? '',
      ),
    );
  }
}

/// Builder per task GitHub Agent.
///
/// Produce un prompt strutturato e delimitato.
///
/// Il prompt viene generato dal Cantiere, non scritto
/// manualmente ogni volta dall'utente.
final class WorkshopAgentTaskPromptBuilder {
  const WorkshopAgentTaskPromptBuilder();

  String build(
    WorkshopTaskContract task, {
    String? projectContext,
    String? architectureContext,
  }) {
    final buffer = StringBuffer();

    buffer.writeln(
      'You are a Senior Software Architect and Engineer.',
    );
    buffer.writeln(
      'Work ONLY on the assigned task.',
    );
    buffer.writeln(
      'Do not expand the scope without explicit approval.',
    );
    buffer.writeln();

    buffer.writeln('TASK ID: ${task.id}');
    buffer.writeln('TASK TITLE: ${task.title}');
    buffer.writeln('TASK KIND: ${task.kind.name}');
    buffer.writeln('OBJECTIVE:');
    buffer.writeln(task.objective);
    buffer.writeln();

    if (projectContext != null &&
        projectContext.trim().isNotEmpty) {
      buffer.writeln('PROJECT CONTEXT:');
      buffer.writeln(projectContext.trim());
      buffer.writeln();
    }

    if (architectureContext != null &&
        architectureContext.trim().isNotEmpty) {
      buffer.writeln('ARCHITECTURE CONTEXT:');
      buffer.writeln(architectureContext.trim());
      buffer.writeln();
    }

    if (task.instructions.isNotEmpty) {
      buffer.writeln('INSTRUCTIONS:');

      for (final instruction in task.instructions) {
        buffer.writeln('- $instruction');
      }

      buffer.writeln();
    }

    if (task.constraints.isNotEmpty) {
      buffer.writeln('CONSTRAINTS:');

      for (final constraint in task.constraints) {
        buffer.writeln('- $constraint');
      }

      buffer.writeln();
    }

    buffer.writeln('FILE SCOPE:');

    if (task.fileScope.allowed.isNotEmpty) {
      buffer.writeln('Allowed:');

      for (final file in task.fileScope.allowed) {
        buffer.writeln('- $file');
      }
    }

    if (task.fileScope.readOnly.isNotEmpty) {
      buffer.writeln('Read-only:');

      for (final file in task.fileScope.readOnly) {
        buffer.writeln('- $file');
      }
    }

    if (task.fileScope.forbidden.isNotEmpty) {
      buffer.writeln('Forbidden:');

      for (final file in task.fileScope.forbidden) {
        buffer.writeln('- $file');
      }
    }

    buffer.writeln();

    buffer.writeln('ACCEPTANCE CRITERIA:');

    for (final criterion in task.acceptanceCriteria) {
      final marker = criterion.required
          ? '[REQUIRED]'
          : '[OPTIONAL]';

      buffer.writeln(
        '- $marker ${criterion.id}: '
        '${criterion.description}',
      );
    }

    buffer.writeln();

    buffer.writeln('CHECKPOINT POLICY:');

    if (task.requiredCheckpoints.isEmpty) {
      buffer.writeln(
        '- Create a checkpoint after the task is verified.',
      );
    } else {
      for (final checkpoint in task.requiredCheckpoints) {
        buffer.writeln('- $checkpoint');
      }
    }

    buffer.writeln();

    buffer.writeln('STOP CONDITIONS:');
    buffer.writeln(
      '- Stop if the requested scope cannot be completed safely.',
    );
    buffer.writeln(
      '- Stop if a forbidden file must be modified.',
    );
    buffer.writeln(
      '- Stop if a dependency outside the allowed scope is required.',
    );
    buffer.writeln(
      '- Stop before starting unrelated work.',
    );

    buffer.writeln();

    buffer.writeln('FINAL REPORT:');
    buffer.writeln(
      '- Files created or modified.',
    );
    buffer.writeln(
      '- Tests executed and results.',
    );
    buffer.writeln(
      '- Lint/static analysis results.',
    );
    buffer.writeln(
      '- Remaining problems.',
    );
    buffer.writeln(
      '- Whether every required acceptance criterion passed.',
    );

    return buffer.toString();
  }
}
