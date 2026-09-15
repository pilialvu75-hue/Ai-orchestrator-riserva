import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';

/// Durable, metadata-only journal for Cloud requests that are allowed to run
/// while the app is in the background.
///
/// A record exists only while the Dart-side request is in flight. If the
/// process dies, its `finally` block cannot remove the record; on the next boot
/// a new journal instance therefore recognizes the old boot id as interrupted.
///
/// Deliberately NOT persisted here: prompt text, system prompt, conversation
/// context, credentials, provider responses or any other user content.
/// Automatic replay is also intentionally excluded: after an abrupt process
/// death the provider may already have accepted/charged the request, so a blind
/// retry could duplicate work or spend.
final class CloudBackgroundExecutionJournal {
  CloudBackgroundExecutionJournal({
    required SharedPreferences preferences,
    String? bootId,
    DateTime Function()? clock,
  })  : _preferences = preferences,
        _bootId = bootId ??
            'boot-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(preferences)}',
        _clock = clock ?? DateTime.now;

  static const String _storageKey =
      'cloud_background_execution_journal_v1';

  final SharedPreferences _preferences;
  final String _bootId;
  final DateTime Function() _clock;

  Future<void> _mutationTail = Future<void>.value();
  int _sequence = 0;

  String get bootId => _bootId;

  Future<CloudBackgroundExecutionRecord?> begin({
    required InferenceRequest request,
    required String providerHint,
  }) {
    return _serialize(() async {
      try {
        final normalizedSession = request.sessionId.trim().isEmpty
            ? 'unknown'
            : request.sessionId.trim();
        final normalizedRequestId = request.requestId?.trim();
        final now = _clock();
        final record = CloudBackgroundExecutionRecord(
          jobId: normalizedRequestId != null && normalizedRequestId.isNotEmpty
              ? 'request-$normalizedRequestId'
              : '$_bootId-$normalizedSession-${now.microsecondsSinceEpoch}-${_sequence++}',
          bootId: _bootId,
          sessionId: normalizedSession,
          requestId:
              normalizedRequestId != null && normalizedRequestId.isNotEmpty
                  ? normalizedRequestId
                  : null,
          providerHint: providerHint.trim().isEmpty
              ? 'auto'
              : providerHint.trim(),
          startedAtEpochMs: now.millisecondsSinceEpoch,
          projectId: _nonEmpty(request.projectId),
          taskId: _nonEmpty(request.taskId),
          executionId: _nonEmpty(request.executionId),
          attemptId: _nonEmpty(request.attemptId),
          checkpointId: _nonEmpty(request.checkpointId),
        );

        final records = _readRecords();
        records.removeWhere((item) => item.jobId == record.jobId);
        records.add(record);
        await _writeRecords(records);

        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] journal_begin job=${record.jobId} '
          'session=${record.sessionId} provider=${record.providerHint}',
        );
        return record;
      } catch (error) {
        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] journal_begin_skipped error=$error',
        );
        return null;
      }
    });
  }

  Future<void> settle(CloudBackgroundExecutionRecord? record) {
    if (record == null) return Future<void>.value();
    return _serialize(() async {
      try {
        final records = _readRecords();
        final before = records.length;
        records.removeWhere((item) => item.jobId == record.jobId);
        if (records.length != before) {
          await _writeRecords(records);
        }
        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] journal_settled job=${record.jobId} '
          'session=${record.sessionId}',
        );
      } catch (error) {
        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] journal_settle_skipped '
          'job=${record.jobId} error=$error',
        );
      }
    });
  }

  Future<List<CloudBackgroundExecutionRecord>>
      consumeInterruptedForSession(String sessionId) {
    return _serialize(() async {
      try {
        final normalizedSession =
            sessionId.trim().isEmpty ? 'unknown' : sessionId.trim();
        final records = _readRecords();
        final interrupted = records
            .where(
              (item) =>
                  item.bootId != _bootId &&
                  item.sessionId == normalizedSession,
            )
            .toList(growable: false);

        if (interrupted.isEmpty) {
          return const <CloudBackgroundExecutionRecord>[];
        }

        final interruptedIds = interrupted.map((item) => item.jobId).toSet();
        records.removeWhere((item) => interruptedIds.contains(item.jobId));
        await _writeRecords(records);

        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] interrupted_consumed '
          'session=$normalizedSession count=${interrupted.length}',
        );
        return interrupted;
      } catch (error) {
        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] interrupted_read_skipped error=$error',
        );
        return const <CloudBackgroundExecutionRecord>[];
      }
    });
  }

  Future<List<CloudBackgroundExecutionRecord>> snapshot() {
    return _serialize(() async {
      try {
        return List<CloudBackgroundExecutionRecord>.unmodifiable(_readRecords());
      } catch (error) {
        debugPrint(
          '[CLOUD_BACKGROUND_RECOVERY] journal_snapshot_skipped error=$error',
        );
        return const <CloudBackgroundExecutionRecord>[];
      }
    });
  }

  List<CloudBackgroundExecutionRecord> _readRecords() {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return <CloudBackgroundExecutionRecord>[];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <CloudBackgroundExecutionRecord>[];
    }

    final records = <CloudBackgroundExecutionRecord>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final normalized = <String, Object?>{};
      item.forEach((key, value) {
        normalized[key.toString()] = value;
      });
      final record = CloudBackgroundExecutionRecord.tryFromJson(normalized);
      if (record != null) records.add(record);
    }
    return records;
  }

  Future<void> _writeRecords(
    List<CloudBackgroundExecutionRecord> records,
  ) async {
    if (records.isEmpty) {
      await _preferences.remove(_storageKey);
      return;
    }

    final encoded = jsonEncode(
      records.map((item) => item.toJson()).toList(growable: false),
    );
    await _preferences.setString(_storageKey, encoded);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

@immutable
final class CloudBackgroundExecutionRecord {
  const CloudBackgroundExecutionRecord({
    required this.jobId,
    required this.bootId,
    required this.sessionId,
    required this.providerHint,
    required this.startedAtEpochMs,
    this.requestId,
    this.projectId,
    this.taskId,
    this.executionId,
    this.attemptId,
    this.checkpointId,
  });

  final String jobId;
  final String bootId;
  final String sessionId;
  final String providerHint;
  final int startedAtEpochMs;
  final String? requestId;
  final String? projectId;
  final String? taskId;
  final String? executionId;
  final String? attemptId;
  final String? checkpointId;

  Map<String, Object?> toJson() => <String, Object?>{
        'jobId': jobId,
        'bootId': bootId,
        'sessionId': sessionId,
        'providerHint': providerHint,
        'startedAtEpochMs': startedAtEpochMs,
        if (requestId != null) 'requestId': requestId,
        if (projectId != null) 'projectId': projectId,
        if (taskId != null) 'taskId': taskId,
        if (executionId != null) 'executionId': executionId,
        if (attemptId != null) 'attemptId': attemptId,
        if (checkpointId != null) 'checkpointId': checkpointId,
      };

  static CloudBackgroundExecutionRecord? tryFromJson(
    Map<String, Object?> json,
  ) {
    final jobId = json['jobId'];
    final bootId = json['bootId'];
    final sessionId = json['sessionId'];
    final providerHint = json['providerHint'];
    final startedAtEpochMs = json['startedAtEpochMs'];
    if (jobId is! String ||
        bootId is! String ||
        sessionId is! String ||
        providerHint is! String ||
        startedAtEpochMs is! num ||
        jobId.trim().isEmpty ||
        bootId.trim().isEmpty ||
        sessionId.trim().isEmpty) {
      return null;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) return null;
      return value.trim();
    }

    return CloudBackgroundExecutionRecord(
      jobId: jobId,
      bootId: bootId,
      sessionId: sessionId,
      providerHint: providerHint,
      startedAtEpochMs: startedAtEpochMs.toInt(),
      requestId: optionalString('requestId'),
      projectId: optionalString('projectId'),
      taskId: optionalString('taskId'),
      executionId: optionalString('executionId'),
      attemptId: optionalString('attemptId'),
      checkpointId: optionalString('checkpointId'),
    );
  }
}
