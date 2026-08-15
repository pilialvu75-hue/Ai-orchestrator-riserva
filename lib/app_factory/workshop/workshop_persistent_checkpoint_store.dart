import 'dart:convert';

import '../../core/config/storage/preferences_service.dart';
import 'workshop_background_service.dart';

/// Persistenza reale dei checkpoint del Cantiere.
///
/// Utilizza il PreferencesService già presente nell'app invece di
/// introdurre un secondo sistema di storage.
///
/// Responsabilità:
/// - salvare l'ultimo checkpoint di ogni job;
/// - recuperare i job dopo la riapertura dell'app;
/// - mantenere separata la persistenza dalla logica del Cantiere.
///
/// Non contiene logica di esecuzione e non prende decisioni sul progetto.
final class PersistentWorkshopCheckpointStore
    implements WorkshopCheckpointStore {
  PersistentWorkshopCheckpointStore({
    required PreferencesService preferences,
  }) : _preferences = preferences;

  final PreferencesService _preferences;

  static const String _storageKey =
      'workshop.background.checkpoints.v1';

  @override
  Future<void> save(
    WorkshopBackgroundCheckpoint checkpoint,
  ) async {
    final items = await _readAll();

    items[checkpoint.jobId] =
        _CheckpointCodec.encode(checkpoint);

    await _writeAll(items);
  }

  @override
  Future<WorkshopBackgroundCheckpoint?> load(
    String jobId,
  ) async {
    final items = await _readAll();

    final encoded = items[jobId];

    if (encoded == null) {
      return null;
    }

    try {
      return _CheckpointCodec.decode(encoded);
    } catch (_) {
      // Un checkpoint corrotto non deve impedire all'app di
      // avviarsi o di recuperare gli altri job.
      return null;
    }
  }

  @override
  Future<List<WorkshopBackgroundCheckpoint>> loadAll() async {
    final items = await _readAll();

    final checkpoints =
        <WorkshopBackgroundCheckpoint>[];

    for (final encoded in items.values) {
      try {
        checkpoints.add(
          _CheckpointCodec.decode(encoded),
        );
      } catch (_) {
        // Ignora solamente il checkpoint corrotto.
      }
    }

    checkpoints.sort(
      (a, b) => b.updatedAt.compareTo(a.updatedAt),
    );

    return List.unmodifiable(checkpoints);
  }

  @override
  Future<void> remove(
    String jobId,
  ) async {
    final items = await _readAll();

    if (!items.containsKey(jobId)) {
      return;
    }

    items.remove(jobId);

    await _writeAll(items);
  }

  Future<Map<String, String>> _readAll() async {
    final raw = _preferences.getString(_storageKey);

    if (raw == null || raw.trim().isEmpty) {
      return <String, String>{};
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! Map) {
        return <String, String>{};
      }

      final result = <String, String>{};

      for (final entry in decoded.entries) {
        if (entry.key is String &&
            entry.value is String) {
          result[entry.key as String] =
              entry.value as String;
        }
      }

      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _writeAll(
    Map<String, String> items,
  ) async {
    await _preferences.setString(
      _storageKey,
      jsonEncode(items),
    );
  }
}

/// Codec interno per la serializzazione del checkpoint.
///
/// Manteniamo il formato esplicito e versionabile: in futuro potremo
/// migrare il formato senza modificare WorkshopBackgroundService.
final class _CheckpointCodec {
  const _CheckpointCodec._();

  static String encode(
    WorkshopBackgroundCheckpoint checkpoint,
  ) {
    return jsonEncode(
      <String, dynamic>{
        'version': 1,
        'jobId': checkpoint.jobId,
        'requestId': checkpoint.requestId,
        'status': checkpoint.status.name,
        'updatedAt': checkpoint.updatedAt.toIso8601String(),
        'projectId': checkpoint.projectId,
        'taskId': checkpoint.taskId,
        'completedTasks': checkpoint.completedTasks,
        'totalTasks': checkpoint.totalTasks,
        'message': checkpoint.message,
        'error': checkpoint.error,
      },
    );
  }

  static WorkshopBackgroundCheckpoint decode(
    String encoded,
  ) {
    final decoded = jsonDecode(encoded);

    if (decoded is! Map) {
      throw const FormatException(
        'Invalid Workshop checkpoint payload.',
      );
    }

    final version = decoded['version'];

    if (version != 1) {
      throw FormatException(
        'Unsupported Workshop checkpoint version: $version',
      );
    }

    final jobId = decoded['jobId'];

    if (jobId is! String || jobId.trim().isEmpty) {
      throw const FormatException(
        'Workshop checkpoint jobId is missing.',
      );
    }

    final requestId = decoded['requestId'];

    if (requestId is! String ||
        requestId.trim().isEmpty) {
      throw const FormatException(
        'Workshop checkpoint requestId is missing.',
      );
    }

    final statusName = decoded['status'];

    if (statusName is! String) {
      throw const FormatException(
        'Workshop checkpoint status is missing.',
      );
    }

    final status = _decodeStatus(statusName);

    final updatedAtValue = decoded['updatedAt'];

    if (updatedAtValue is! String) {
      throw const FormatException(
        'Workshop checkpoint updatedAt is missing.',
      );
    }

    final updatedAt =
        DateTime.parse(updatedAtValue);

    return WorkshopBackgroundCheckpoint(
      jobId: jobId,
      requestId: requestId,
      status: status,
      updatedAt: updatedAt,
      projectId: _nullableString(
        decoded['projectId'],
      ),
      taskId: _nullableString(
        decoded['taskId'],
      ),
      completedTasks: _integer(
        decoded['completedTasks'],
      ),
      totalTasks: _integer(
        decoded['totalTasks'],
      ),
      message: _nullableString(
        decoded['message'],
      ),
      error: _nullableString(
        decoded['error'],
      ),
    );
  }

  static WorkshopBackgroundStatus _decodeStatus(
    String value,
  ) {
    for (final status
        in WorkshopBackgroundStatus.values) {
      if (status.name == value) {
        return status;
      }
    }

    throw FormatException(
      'Unknown Workshop background status: $value',
    );
  }

  static String? _nullableString(
    Object? value,
  ) {
    return value is String ? value : null;
  }

  static int _integer(
    Object? value,
  ) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    return 0;
  }
}
