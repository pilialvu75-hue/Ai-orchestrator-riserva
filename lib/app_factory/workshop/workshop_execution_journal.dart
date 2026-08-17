/// Registro operativo del Cantiere.
///
/// Il Journal conserva la storia delle esecuzioni senza dipendere
/// direttamente dal Dispatcher, dall'Executor o dai provider AI.
///
/// Questo permette di usarlo sia con:
///
/// - Local;
/// - HYBRID;
/// - Cloud;
/// - GitHub Agent;
/// - Gemini;
/// - Claude;
/// - OpenAI;
/// - altri provider futuri.
///
/// Il Journal non decide quale risorsa usare e non esegue task.
/// Registra ciò che è già avvenuto.
///
/// In futuro questa implementazione potrà essere sostituita
/// internamente da SQLite/Isar senza modificare il contratto pubblico.
final class WorkshopExecutionRecord {
  const WorkshopExecutionRecord({
    required this.id,
    required this.taskId,
    required this.status,
    required this.startedAt,
    required this.completedAt,
    this.resource,
    this.providerId,
    this.mode,
    this.message,
    this.error,
    this.checkpoint,
    this.changedFiles = const <String>[],
    this.artifacts = const <String>[],
    this.metadata = const <String, dynamic>{},
    this.estimatedCredits = 0,
    this.consumedCredits = 0,
    this.latencyMs = 0,
    this.usedFallback = false,
  });

  final String id;
  final String taskId;

  /// Stato serializzato intenzionalmente come String.
  ///
  /// Evita che il Journal dipenda dagli enum dell'Executor.
  final String status;

  final DateTime startedAt;
  final DateTime completedAt;

  final String? resource;
  final String? providerId;
  final String? mode;
  final String? message;
  final String? error;
  final String? checkpoint;

  final List<String> changedFiles;
  final List<String> artifacts;

  final Map<String, dynamic> metadata;

  final double estimatedCredits;
  final double consumedCredits;

  final int latencyMs;

  final bool usedFallback;

  bool get succeeded =>
      status.toLowerCase() == 'completed' ||
      status.toLowerCase() == 'success' ||
      status.toLowerCase() == 'succeeded';

  bool get failed =>
      status.toLowerCase() == 'failed' ||
      status.toLowerCase() == 'error';

  bool get waiting =>
      status.toLowerCase() == 'waitingapproval' ||
      status.toLowerCase() == 'waiting_approval' ||
      status.toLowerCase() == 'waiting-approval';

  bool get cancelled =>
      status.toLowerCase() == 'cancelled' ||
      status.toLowerCase() == 'canceled';

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'taskId': taskId,
      'status': status,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'completedAt': completedAt.toUtc().toIso8601String(),
      'resource': resource,
      'providerId': providerId,
      'mode': mode,
      'message': message,
      'error': error,
      'checkpoint': checkpoint,
      'changedFiles': List<String>.unmodifiable(
        changedFiles,
      ),
      'artifacts': List<String>.unmodifiable(
        artifacts,
      ),
      'metadata': Map<String, dynamic>.unmodifiable(
        metadata,
      ),
      'estimatedCredits': estimatedCredits,
      'consumedCredits': consumedCredits,
      'latencyMs': latencyMs,
      'usedFallback': usedFallback,
    };
  }

  factory WorkshopExecutionRecord.fromJson(
    Map<String, dynamic> json,
  ) {
    return WorkshopExecutionRecord(
      id: json['id'] as String,
      taskId: json['taskId'] as String,
      status: json['status'] as String,
      startedAt: DateTime.parse(
        json['startedAt'] as String,
      ).toUtc(),
      completedAt: DateTime.parse(
        json['completedAt'] as String,
      ).toUtc(),
      resource: json['resource'] as String?,
      providerId: json['providerId'] as String?,
      mode: json['mode'] as String?,
      message: json['message'] as String?,
      error: json['error'] as String?,
      checkpoint: json['checkpoint'] as String?,
      changedFiles:
          _stringList(json['changedFiles']),
      artifacts:
          _stringList(json['artifacts']),
      metadata:
          _map(json['metadata']),
      estimatedCredits:
          _doubleValue(
        json['estimatedCredits'],
      ),
      consumedCredits:
          _doubleValue(
        json['consumedCredits'],
      ),
      latencyMs:
          _intValue(json['latencyMs']),
      usedFallback:
          json['usedFallback'] == true,
    );
  }

  WorkshopExecutionRecord copyWith({
    String? id,
    String? taskId,
    String? status,
    DateTime? startedAt,
    DateTime? completedAt,
    String? resource,
    String? providerId,
    String? mode,
    String? message,
    String? error,
    String? checkpoint,
    List<String>? changedFiles,
    List<String>? artifacts,
    Map<String, dynamic>? metadata,
    double? estimatedCredits,
    double? consumedCredits,
    int? latencyMs,
    bool? usedFallback,
  }) {
    return WorkshopExecutionRecord(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      resource: resource ?? this.resource,
      providerId: providerId ?? this.providerId,
      mode: mode ?? this.mode,
      message: message ?? this.message,
      error: error ?? this.error,
      checkpoint: checkpoint ?? this.checkpoint,
      changedFiles:
          changedFiles ?? this.changedFiles,
      artifacts:
          artifacts ?? this.artifacts,
      metadata:
          metadata ?? this.metadata,
      estimatedCredits:
          estimatedCredits ?? this.estimatedCredits,
      consumedCredits:
          consumedCredits ?? this.consumedCredits,
      latencyMs:
          latencyMs ?? this.latencyMs,
      usedFallback:
          usedFallback ?? this.usedFallback,
    );
  }
}

/// Statistiche aggregate del Journal.
final class WorkshopExecutionJournalStats {
  const WorkshopExecutionJournalStats({
    required this.totalExecutions,
    required this.successfulExecutions,
    required this.failedExecutions,
    required this.waitingExecutions,
    required this.cancelledExecutions,
    required this.fallbackExecutions,
    required this.totalConsumedCredits,
    required this.averageLatencyMs,
  });

  final int totalExecutions;
  final int successfulExecutions;
  final int failedExecutions;
  final int waitingExecutions;
  final int cancelledExecutions;
  final int fallbackExecutions;

  final double totalConsumedCredits;
  final double averageLatencyMs;

  double get successRate {
    if (totalExecutions == 0) {
      return 0;
    }

    return successfulExecutions / totalExecutions;
  }

  double get failureRate {
    if (totalExecutions == 0) {
      return 0;
    }

    return failedExecutions / totalExecutions;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'totalExecutions': totalExecutions,
      'successfulExecutions':
          successfulExecutions,
      'failedExecutions':
          failedExecutions,
      'waitingExecutions':
          waitingExecutions,
      'cancelledExecutions':
          cancelledExecutions,
      'fallbackExecutions':
          fallbackExecutions,
      'totalConsumedCredits':
          totalConsumedCredits,
      'averageLatencyMs':
          averageLatencyMs,
      'successRate':
          successRate,
      'failureRate':
          failureRate,
    };
  }
}

/// Journal in-memory del Cantiere.
///
/// L'implementazione è volutamente semplice:
/// il livello superiore può successivamente collegarlo
/// a una persistenza reale.
final class WorkshopExecutionJournal {
  WorkshopExecutionJournal({
    List<WorkshopExecutionRecord> initialRecords =
        const <WorkshopExecutionRecord>[],
  }) : _records = <WorkshopExecutionRecord>[
          ...initialRecords,
        ];

  final List<WorkshopExecutionRecord> _records;

  List<WorkshopExecutionRecord> get records =>
      List<WorkshopExecutionRecord>.unmodifiable(
        _records,
      );

  int get length => _records.length;

  bool get isEmpty => _records.isEmpty;

  bool get isNotEmpty => _records.isNotEmpty;

  void record(
    WorkshopExecutionRecord execution,
  ) {
    _records.add(execution);
  }

  void recordAll(
    Iterable<WorkshopExecutionRecord> executions,
  ) {
    _records.addAll(executions);
  }

  WorkshopExecutionRecord? findById(
    String id,
  ) {
    for (final record in _records) {
      if (record.id == id) {
        return record;
      }
    }

    return null;
  }

  List<WorkshopExecutionRecord> findByTaskId(
    String taskId,
  ) {
    return List<WorkshopExecutionRecord>.unmodifiable(
      _records.where(
        (record) => record.taskId == taskId,
      ),
    );
  }

  List<WorkshopExecutionRecord> findByProvider(
    String providerId,
  ) {
    return List<WorkshopExecutionRecord>.unmodifiable(
      _records.where(
        (record) =>
            record.providerId == providerId,
      ),
    );
  }

  List<WorkshopExecutionRecord> findByResource(
    String resource,
  ) {
    return List<WorkshopExecutionRecord>.unmodifiable(
      _records.where(
        (record) =>
            record.resource == resource,
      ),
    );
  }

  List<WorkshopExecutionRecord> findByStatus(
    String status,
  ) {
    final normalized =
        status.trim().toLowerCase();

    return List<WorkshopExecutionRecord>.unmodifiable(
      _records.where(
        (record) =>
            record.status.toLowerCase() ==
            normalized,
      ),
    );
  }

  List<WorkshopExecutionRecord> recent({
    int limit = 20,
  }) {
    if (limit <= 0 || _records.isEmpty) {
      return const <WorkshopExecutionRecord>[];
    }

    final sorted =
        List<WorkshopExecutionRecord>.from(
      _records,
    )..sort(
        (a, b) =>
            b.completedAt.compareTo(
          a.completedAt,
        ),
      );

    final count =
        limit < sorted.length
            ? limit
            : sorted.length;

    return List<WorkshopExecutionRecord>.unmodifiable(
      sorted.take(count),
    );
  }

  WorkshopExecutionJournalStats get stats {
    if (_records.isEmpty) {
      return const WorkshopExecutionJournalStats(
        totalExecutions: 0,
        successfulExecutions: 0,
        failedExecutions: 0,
        waitingExecutions: 0,
        cancelledExecutions: 0,
        fallbackExecutions: 0,
        totalConsumedCredits: 0,
        averageLatencyMs: 0,
      );
    }

    var successful = 0;
    var failed = 0;
    var waiting = 0;
    var cancelled = 0;
    var fallback = 0;
    var credits = 0.0;
    var latency = 0;

    for (final record in _records) {
      if (record.succeeded) {
        successful++;
      }

      if (record.failed) {
        failed++;
      }

      if (record.waiting) {
        waiting++;
      }

      if (record.cancelled) {
        cancelled++;
      }

      if (record.usedFallback) {
        fallback++;
      }

      credits += record.consumedCredits;
      latency += record.latencyMs;
    }

    return WorkshopExecutionJournalStats(
      totalExecutions:
          _records.length,
      successfulExecutions:
          successful,
      failedExecutions:
          failed,
      waitingExecutions:
          waiting,
      cancelledExecutions:
          cancelled,
      fallbackExecutions:
          fallback,
      totalConsumedCredits:
          credits,
      averageLatencyMs:
          latency / _records.length,
    );
  }

  /// Numero di esecuzioni per provider.
  Map<String, int> executionsByProvider() {
    final result = <String, int>{};

    for (final record in _records) {
      final provider =
          record.providerId ?? 'unknown';

      result[provider] =
          (result[provider] ?? 0) + 1;
    }

    return Map<String, int>.unmodifiable(
      result,
    );
  }

  /// Numero di esecuzioni per risorsa.
  Map<String, int> executionsByResource() {
    final result = <String, int>{};

    for (final record in _records) {
      final resource =
          record.resource ?? 'unknown';

      result[resource] =
          (result[resource] ?? 0) + 1;
    }

    return Map<String, int>.unmodifiable(
      result,
    );
  }

  /// Consumo totale per provider.
  Map<String, double> creditsByProvider() {
    final result = <String, double>{};

    for (final record in _records) {
      final provider =
          record.providerId ?? 'unknown';

      result[provider] =
          (result[provider] ?? 0) +
              record.consumedCredits;
    }

    return Map<String, double>.unmodifiable(
      result,
    );
  }

  /// Rimuove una singola registrazione.
  bool removeById(String id) {
    final index =
        _records.indexWhere(
      (record) => record.id == id,
    );

    if (index < 0) {
      return false;
    }

    _records.removeAt(index);
    return true;
  }

  /// Svuota il journal in memoria.
  ///
  /// La persistenza esterna, se presente, deve essere gestita
  /// dal repository adapter che utilizza questo Journal.
  void clear() {
    _records.clear();
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'records': _records
          .map(
            (record) => record.toJson(),
          )
          .toList(
            growable: false,
          ),
      'stats': stats.toJson(),
    };
  }

  factory WorkshopExecutionJournal.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawRecords =
        json['records'];

    if (rawRecords is! List) {
      return WorkshopExecutionJournal();
    }

    final records =
        <WorkshopExecutionRecord>[];

    for (final value in rawRecords) {
      if (value is Map) {
        records.add(
          WorkshopExecutionRecord.fromJson(
            Map<String, dynamic>.from(
              value,
            ),
          ),
        );
      }
    }

    return WorkshopExecutionJournal(
      initialRecords: records,
    );
  }

  static List<String> _stringList(
    dynamic value,
  ) {
    if (value is! List) {
      return const <String>[];
    }

    return value
        .whereType<String>()
        .toList(
          growable: false,
        );
  }

  static Map<String, dynamic> _map(
    dynamic value,
  ) {
    if (value is! Map) {
      return const <String, dynamic>{};
    }

    return Map<String, dynamic>.from(
      value,
    );
  }

  static double _doubleValue(
    dynamic value,
  ) {
    if (value is num) {
      return value.toDouble();
    }

    return 0;
  }

  static int _intValue(
    dynamic value,
  ) {
    if (value is num) {
      return value.toInt();
    }

    return 0;
  }
}
