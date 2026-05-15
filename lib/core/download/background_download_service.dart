import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/download/download_session_manager.dart';

class BackgroundDownloadService {
  BackgroundDownloadService({DownloadSessionManager? sessionManager})
      : _sessionManager = sessionManager ?? DownloadSessionManager();

  final DownloadSessionManager _sessionManager;
  final HttpClient _httpClient = HttpClient();

  Future<DownloadSession> startDownload({
    required String url,
    required String destinationPath,
  }) async {
    debugPrint(
      '[DOWNLOAD] WARNING – background persistence requires a native Android '
      'foreground service; this implementation runs in the foreground only.',
    );

    var session = _sessionManager.createSession(
      url: url,
      destinationPath: destinationPath,
    );

    session = session.copyWith(
      status: DownloadSessionStatus.downloading,
      startedAt: DateTime.now(),
    );
    _sessionManager.updateSession(session.id, session);

    _runDownload(session);

    return session;
  }

  void _runDownload(DownloadSession session) {
    Future(() async {
      IOSink? fileSink;
      try {
        final request = await _httpClient.getUrl(Uri.parse(session.url));
        final response = await request.close();

        final totalBytes = response.contentLength > 0
            ? response.contentLength
            : 0;

        final file = File(session.destinationPath);
        await file.parent.create(recursive: true);
        fileSink = file.openWrite();

        int bytesDownloaded = 0;
        // Cache the current session once to avoid repeated map lookups
        // on every received chunk.
        var currentSession = await _currentSession(session.id);
        await for (final chunk in response) {
          fileSink.add(chunk);
          bytesDownloaded += chunk.length;

          final progress = totalBytes > 0
              ? (bytesDownloaded / totalBytes).clamp(0.0, 1.0)
              : 0.0;

          currentSession = currentSession.copyWith(
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            progress: progress,
          );
          _sessionManager.updateSession(session.id, currentSession);
        }

        await fileSink.flush();
        await fileSink.close();
        fileSink = null;

        _sessionManager.updateSession(
          session.id,
          currentSession.copyWith(
            status: DownloadSessionStatus.completed,
            progress: 1.0,
            completedAt: DateTime.now(),
          ),
        );
        debugPrint('[DOWNLOAD] Completed: ${session.id}');
      } catch (e) {
        await fileSink?.close();
        final current = _sessionManager.getSession(session.id);
        if (current != null && current.status != DownloadSessionStatus.cancelled) {
          _sessionManager.updateSession(
            session.id,
            current.copyWith(
              status: DownloadSessionStatus.failed,
              error: e.toString(),
            ),
          );
          debugPrint('[DOWNLOAD] Failed: ${session.id} – $e');
        }
      }
    });
  }

  Future<DownloadSession> _currentSession(String id) async {
    final session = _sessionManager.getSession(id);
    if (session == null) {
      throw StateError('Download session not found: $id');
    }
    return session;
  }

  void cancelDownload(String sessionId) {
    _sessionManager.cancelSession(sessionId);
    debugPrint('[DOWNLOAD] Cancel requested: $sessionId');
  }

  Stream<DownloadSession> watchSession(String sessionId) =>
      _sessionManager.sessionUpdates
          .where((session) => session.id == sessionId);
}
