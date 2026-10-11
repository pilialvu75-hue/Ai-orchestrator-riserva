import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';
import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_resource_exchange.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_storage_lock.dart';

enum WorkshopWebProjectStatus {
  draft,
  proposalReady,
  approved,
  inProgress,
  blocked,
  completed,
}

final class WorkshopWebProject {
  const WorkshopWebProject({
    required this.id,
    required this.title,
    required this.goal,
    required this.platforms,
    required this.status,
    required this.progress,
    required this.currentPhase,
    required this.currentItem,
    required this.createdAt,
    required this.updatedAt,
    this.proposal,
    this.error,
    this.extension,
    this.storageRevision = 0,
    Map<String, Object?> preservedFields = const <String, Object?>{},
  }) : _preservedFields = preservedFields;

  final String id;
  final String title;
  final String goal;
  final List<String> platforms;
  final WorkshopWebProjectStatus status;
  final double progress;
  final String currentPhase;
  final String currentItem;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? proposal;
  final String? error;
  final AivexusProjectExtension? extension;
  final int storageRevision;
  final Map<String, Object?> _preservedFields;

  AivexusProjectKind? get projectKind =>
      extension == null ? AivexusProjectKind.software : extension!.kind;
  bool get isReadOnly => extension?.isReadOnly ?? false;

  WorkshopWebProject copyWith({
    String? title,
    String? goal,
    List<String>? platforms,
    WorkshopWebProjectStatus? status,
    double? progress,
    String? currentPhase,
    String? currentItem,
    String? proposal,
    String? error,
    bool clearError = false,
    bool clearProposal = false,
    AivexusProjectExtension? extension,
    int? storageRevision,
    DateTime? updatedAt,
  }) {
    return WorkshopWebProject(
      id: id,
      title: title ?? this.title,
      goal: goal ?? this.goal,
      platforms: List<String>.unmodifiable(platforms ?? this.platforms),
      status: status ?? this.status,
      progress: (progress ?? this.progress).clamp(0.0, 1.0).toDouble(),
      currentPhase: currentPhase ?? this.currentPhase,
      currentItem: currentItem ?? this.currentItem,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
      proposal: clearProposal ? null : proposal ?? this.proposal,
      error: clearError ? null : error ?? this.error,
      extension: extension ?? this.extension,
      storageRevision: storageRevision ?? this.storageRevision,
      preservedFields: _preservedFields,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...Map<String, Object?>.from(
      jsonDecode(jsonEncode(_preservedFields)) as Map,
    ),
    'id': id,
    'title': title,
    'goal': goal,
    'platforms': platforms,
    'status': status.name,
    'progress': progress,
    'currentPhase': currentPhase,
    'currentItem': currentItem,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'proposal': proposal,
    'error': error,
    'storageRevision': storageRevision,
    if (extension != null) 'extension': extension!.toJson(),
  };

  static WorkshopWebProject? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final title = raw['title'];
    final goal = raw['goal'];
    final platforms = raw['platforms'];
    final statusName = raw['status'];
    final progress = raw['progress'];
    final currentPhase = raw['currentPhase'];
    final currentItem = raw['currentItem'];
    final createdAt = DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(raw['updatedAt']?.toString() ?? '');
    if (id is! String ||
        title is! String ||
        goal is! String ||
        platforms is! List ||
        statusName is! String ||
        progress is! num ||
        currentPhase is! String ||
        currentItem is! String ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }

    WorkshopWebProjectStatus? status;
    for (final candidate in WorkshopWebProjectStatus.values) {
      if (candidate.name == statusName) {
        status = candidate;
        break;
      }
    }
    if (status == null) return null;
    final revision = raw['storageRevision'] ?? 0;
    if (revision is! int || revision < 0) return null;

    return WorkshopWebProject(
      id: id,
      title: title,
      goal: goal,
      platforms: List<String>.unmodifiable(
        platforms
            .whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty),
      ),
      status: status,
      progress: progress.toDouble().clamp(0.0, 1.0).toDouble(),
      currentPhase: currentPhase,
      currentItem: currentItem,
      createdAt: createdAt,
      updatedAt: updatedAt,
      proposal: raw['proposal'] is String ? raw['proposal'] as String : null,
      error: raw['error'] is String ? raw['error'] as String : null,
      extension: raw.containsKey('extension')
          ? AivexusProjectExtension.read(raw['extension'])
          : null,
      storageRevision: revision,
      preservedFields: Map<String, Object?>.from(raw),
    );
  }
}

final class WorkshopWebProjectStorage {
  WorkshopWebProjectStorage._(this._preferences);

  static const String _storageKey = 'workshop.web.projects.v1';
  static const String backupKey =
      'workshop.web.projects.v1.backup.before-extension-v1';

  final SharedPreferences _preferences;

  static Future<WorkshopWebProjectStorage> open() async {
    final preferences = await SharedPreferences.getInstance();
    return WorkshopWebProjectStorage._(preferences);
  }

  Future<List<WorkshopWebProject>> loadAll() async {
    await _preferences.reload();
    final envelope = _readEnvelope();
    final projects = _projects(envelope)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<WorkshopWebProject>.unmodifiable(projects);
  }

  Map<String, dynamic> _readEnvelope() {
    final raw = _preferences.getString(_storageKey);
    if (raw == null) {
      return <String, dynamic>{'version': 1, 'projects': <Object?>[]};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['projects'] is! List) {
        throw const FormatException('Unsupported project envelope');
      }
      return decoded;
    } catch (_) {
      throw const FormatException(
        'Archivio progetti non leggibile. I dati originali sono conservati.',
      );
    }
  }

  List<WorkshopWebProject> _projects(Map<String, dynamic> envelope) {
    final projects = <WorkshopWebProject>[];
    final ids = <String>{};
    for (final raw in envelope['projects'] as List) {
      final project = WorkshopWebProject.fromJson(raw);
      if (project == null || !ids.add(project.id)) {
        throw const FormatException(
          'Archivio con progetti non riconosciuti. Nessun dato è stato modificato.',
        );
      }
      projects.add(project);
    }
    return projects;
  }

  /// Upserts only supplied projects. Missing rows never mean deletion.
  /// Retained for existing callers; new code should consume saveProject's result.
  Future<void> save(Iterable<WorkshopWebProject> projects) async {
    final updates = projects.toList(growable: false);
    await _mutate((envelope) {
      for (final project in updates) {
        _upsert(envelope, project);
      }
    });
  }

  /// Revision compare-and-swap runs inside an origin-wide browser lock.
  Future<WorkshopWebProject> saveProject(WorkshopWebProject project) =>
      _mutate((envelope) => _upsert(envelope, project));

  WorkshopWebProject _upsert(
    Map<String, dynamic> envelope,
    WorkshopWebProject project,
  ) {
    final projects = _projects(envelope);
    final index = projects.indexWhere((item) => item.id == project.id);
    final previous = index < 0 ? null : projects[index];
    if (previous != null) {
      final before = previous.toJson()
        ..remove('updatedAt')
        ..remove('storageRevision');
      final after = project.toJson()
        ..remove('updatedAt')
        ..remove('storageRevision');
      if (aivexusCanonicalJson(before) == aivexusCanonicalJson(after))
        return previous;
    }
    if (project.isReadOnly || (previous?.isReadOnly ?? false)) {
      throw StateError(
        'Progetto aperto in sola lettura: estensione non supportata.',
      );
    }
    if (project.storageRevision != (previous?.storageRevision ?? 0)) {
      throw const WorkshopWebProjectConflict();
    }
    if (previous != null && previous.projectKind != project.projectKind) {
      throw StateError(
        'Il tipo di un progetto esistente non può essere cambiato.',
      );
    }
    if (previous?.extension != null) {
      final oldExtension = previous!.extension!;
      final nextExtension = project.extension!;
      final before = Map<String, Object?>.from(oldExtension.toJson()! as Map)
        ..remove('artifacts')
        ..remove('validationRefs')
        ..remove('specRevision');
      final after = Map<String, Object?>.from(nextExtension.toJson()! as Map)
        ..remove('artifacts')
        ..remove('validationRefs')
        ..remove('specRevision');
      final changed =
          aivexusCanonicalJson(before) != aivexusCanonicalJson(after) ||
          previous.goal != project.goal ||
          aivexusCanonicalJson(previous.platforms) !=
              aivexusCanonicalJson(project.platforms);
      if (nextExtension.specRevision! < oldExtension.specRevision! ||
          (changed &&
              nextExtension.specRevision! <= oldExtension.specRevision!)) {
        throw StateError(
          'La specifica modificata richiede una nuova revisione.',
        );
      }
      final oldArtifacts = (oldExtension.toJson()! as Map)['artifacts'] as List;
      final nextArtifacts =
          (nextExtension.toJson()! as Map)['artifacts'] as List;
      if (!oldArtifacts.every(
        (artifact) => nextArtifacts.any(
          (next) =>
              aivexusCanonicalJson(artifact) == aivexusCanonicalJson(next),
        ),
      )) {
        throw StateError(
          'Gli artefatti già prodotti devono restare nella cronologia.',
        );
      }
    }
    final saved = WorkshopWebProject.fromJson(<String, dynamic>{
      if (previous != null) ...previous.toJson(),
      ...project.toJson(),
      'storageRevision': (previous?.storageRevision ?? 0) + 1,
      if (previous != null) 'createdAt': previous.createdAt.toIso8601String(),
    })!;
    final rows = envelope['projects'] as List;
    if (index < 0) {
      rows.add(saved.toJson());
    } else {
      rows[index] = saved.toJson();
    }
    return saved;
  }

  Future<List<AivexusResourceExchange>> loadResourceExchanges() async {
    await _preferences.reload();
    final raw = _readEnvelope()['resourceExchanges'];
    if (raw == null) return const <AivexusResourceExchange>[];
    if (raw is! Map) throw const FormatException('Invalid exchange archive');
    return raw.values.map(AivexusResourceExchange.read).toList(growable: false);
  }

  Future<AivexusResourceExchange> saveResourceExchange(
    AivexusResourceExchange exchange,
  ) => _mutate((envelope) {
    final projects = _projects(envelope);
    final requester = projects.where(
      (p) => p.id == exchange.requesterProjectId,
    );
    if (requester.isEmpty)
      throw StateError('Progetto richiedente inesistente.');
    if (requester.single.isReadOnly)
      throw StateError('Progetto richiedente in sola lettura.');
    final records = envelope.putIfAbsent(
      'resourceExchanges',
      () => <String, dynamic>{},
    );
    if (records is! Map)
      throw const FormatException('Invalid exchange archive');
    final raw = records[exchange.requestId];
    final previous = raw == null ? null : AivexusResourceExchange.read(raw);
    if (previous != null) {
      if (previous.semanticIdentity != exchange.semanticIdentity) {
        throw StateError('requestId già usato per una richiesta differente.');
      }
      // Retrying the same initial request never resets produced/accepted work.
      if (exchange.recordRevision == 0 && exchange.status == 'requested')
        return previous;
      if (aivexusCanonicalJson(previous.toJson()) ==
          aivexusCanonicalJson(exchange.toJson())) {
        return previous;
      }
    } else if (exchange.status != 'requested' ||
        (requester.single.extension?.specRevision ?? 1) !=
            exchange.requesterSpecRevision) {
      throw StateError(
        'Richiesta iniziale non riferita alla revisione corrente.',
      );
    }
    if (exchange.recordRevision != (previous?.recordRevision ?? 0)) {
      throw const WorkshopWebProjectConflict();
    }
    if (previous != null && !previous.canTransitionTo(exchange.status)) {
      throw StateError('Transizione richiesta non consentita.');
    }
    final produced = exchange.result;
    if (produced != null) {
      final producer = projects.where(
        (p) => p.id == produced['producerProjectId'],
      );
      if (producer.isEmpty ||
          producer.single.isReadOnly ||
          producer.single.extension == null) {
        throw StateError('Progetto produttore non disponibile.');
      }
      final artifacts =
          (producer.single.extension!.toJson()! as Map)['artifacts'] as List;
      if (!artifacts.any(
        (artifact) =>
            (artifact as Map)['ref'] == produced['artifactRef'] &&
            artifact['sha256'] == produced['sha256'] &&
            artifact['sizeBytes'] == produced['sizeBytes'] &&
            artifact['sourceSpecRevision'] == produced['producerSpecRevision'],
      )) {
        throw StateError(
          'Il risultato non corrisponde a un artefatto persistito.',
        );
      }
    }
    final saved = exchange.withRecordRevision(
      (previous?.recordRevision ?? 0) + 1,
    );
    records[exchange.requestId] = saved.toJson();
    return saved;
  });

  Future<T> _mutate<T>(
    T Function(Map<String, dynamic>) action,
  ) => withWorkshopStorageLock(_storageKey, () async {
    await _preferences.reload();
    final original = _preferences.getString(_storageKey);
    final envelope = _readEnvelope();
    final result = action(envelope);
    final encoded = jsonEncode(envelope);
    if (encoded == original) return result;
    if (original != null && _preferences.getString(backupKey) == null) {
      if (!await _preferences.setString(backupKey, original)) {
        throw StateError(
          'Impossibile salvare la copia recuperabile dei progetti.',
        );
      }
    }
    // No 100-row truncation. Quota errors reach the UI; old data stays intact.
    if (!await _preferences.setString(_storageKey, encoded)) {
      throw StateError(
        'Salvataggio non riuscito. Controlla lo spazio disponibile.',
      );
    }
    return result;
  });
}

final class WorkshopWebProjectConflict implements Exception {
  const WorkshopWebProjectConflict();
  @override
  String toString() =>
      'Il progetto è stato modificato in un’altra scheda. Ricaricalo prima di riprovare.';
}
