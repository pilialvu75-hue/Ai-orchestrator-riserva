import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

enum DownloadSessionStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

@immutable
class DownloadSession {
  const DownloadSession({
    required this.id,
    required this.url,
    required this.destinationPath,
    this.progress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.status = DownloadSessionStatus.pending,
    this.error,
    this.startedAt,
    this.completedAt,
  });

  final String id;
  final String url;
  final String destinationPath;
  final double progress;
  final int bytesDownloaded;
  final int totalBytes;
  final DownloadSessionStatus status;
  final String? error;
  final DateTime? startedAt;
  final DateTime? completedAt;

  DownloadSession copyWith({
    String? id,
    String? url,
    String? destinationPath,
    double? progress,
    int? bytesDownloaded,
    int? totalBytes,
    DownloadSessionStatus? status,
    Object? error = _sentinel,
    Object? startedAt = _sentinel,
    Object? completedAt = _sentinel,
  }) {
    return DownloadSession(
      id: id ?? this.id,
      url: url ?? this.url,
      destinationPath: destinationPath ?? this.destinationPath,
      progress: progress ?? this.progress,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      status: status ?? this.status,
      error: error == _sentinel ? this.error : error as String?,
      startedAt: startedAt == _sentinel ? this.startedAt : startedAt as DateTime?,
      completedAt:
          completedAt == _sentinel ? this.completedAt : completedAt as DateTime?,
    );
  }

  static const Object _sentinel = Object();

  @override
  String toString() =>
      'DownloadSession(id: $id, status: $status, progress: $progress, '
      'url: $url)';
}

class DownloadSessionManager {
  static const _uuid = Uuid();

  final Map<String, DownloadSession> _sessions = {};

  final StreamController<DownloadSession> _streamController =
      StreamController<DownloadSession>.broadcast();

  Stream<DownloadSession> get sessionUpdates => _streamController.stream;

  DownloadSession createSession({
    required String url,
    required String destinationPath,
  }) {
    final session = DownloadSession(
      id: _uuid.v4(),
      url: url,
      destinationPath: destinationPath,
    );
    _sessions[session.id] = session;
    _streamController.add(session);
    debugPrint('[DOWNLOAD] Session created: ${session.id} for $url');
    return session;
  }

  DownloadSession? getSession(String id) => _sessions[id];

  void updateSession(String id, DownloadSession updated) {
    _sessions[id] = updated;
    _streamController.add(updated);
  }

  void cancelSession(String id) {
    final session = _sessions[id];
    if (session == null) return;

    final cancelled = session.copyWith(status: DownloadSessionStatus.cancelled);
    _sessions[id] = cancelled;
    _streamController.add(cancelled);
    debugPrint('[DOWNLOAD] Session cancelled: $id');
  }

  List<DownloadSession> getActiveSessions() => _sessions.values
      .where((s) =>
          s.status == DownloadSessionStatus.pending ||
          s.status == DownloadSessionStatus.downloading ||
          s.status == DownloadSessionStatus.paused)
      .toList();

  List<DownloadSession> getCompletedSessions() => _sessions.values
      .where((s) => s.status == DownloadSessionStatus.completed)
      .toList();
}
