import 'dart:io';

import 'package:ai_orchestrator/core/sync/network/sync_protocol.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';

/// Local HTTP server that exposes CRDT sync endpoints on the LAN.
///
/// Once [start] is called the server listens on [port] (default 47847) and
/// processes the three endpoints defined in [SyncProtocol].  All traffic stays
/// on the local network – no data is sent to any cloud service.
///
/// Typical lifecycle:
/// ```dart
/// final server = LocalSyncServer(
///   syncManager: sl<SyncManager>(),
///   deviceName: 'My Phone',
/// );
/// await server.start();
/// // ... app running ...
/// await server.stop();
/// ```
class LocalSyncServer {
  LocalSyncServer({
    required SyncManager syncManager,
    required String deviceName,
    this.port = 47847,
  })  : _syncManager = syncManager,
        _deviceName = deviceName;

  final SyncManager _syncManager;
  final String _deviceName;
  final int port;

  HttpServer? _server;

  bool get isRunning => _server != null;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Starts the HTTP server.  Binds to all network interfaces so that peers
  /// on the same LAN (Wi-Fi / USB) can reach it.
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest, onError: _onServerError);
  }

  /// Stops the HTTP server and releases the port.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // ── Request handling ──────────────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == SyncProtocol.pathInfo && request.method == 'GET') {
        await _handleInfo(request);
      } else if (path == SyncProtocol.pathChanges && request.method == 'GET') {
        await _handleChanges(request);
      } else if (path == SyncProtocol.pathPush && request.method == 'POST') {
        await _handlePush(request);
      } else {
        _sendJson(request.response, HttpStatus.notFound,
            SyncProtocol.errorResponse('Not found'));
      }
    } catch (e) {
      _sendJson(request.response, HttpStatus.internalServerError,
          SyncProtocol.errorResponse('Internal error: $e'));
    }
  }

  Future<void> _handleInfo(HttpRequest request) async {
    final maxHlc = await _syncManager.maxHlc();
    _sendJson(
      request.response,
      HttpStatus.ok,
      SyncProtocol.infoResponse(
        deviceId: _syncManager.nodeId,
        deviceName: _deviceName,
        maxHlc: maxHlc,
      ),
    );
  }

  Future<void> _handleChanges(HttpRequest request) async {
    final sinceParam =
        request.uri.queryParameters[SyncProtocol.queryParamSince];
    final records = await _syncManager.exportChangesSince(sinceParam);
    _sendJson(
        request.response, HttpStatus.ok, SyncProtocol.changesResponse(records));
  }

  Future<void> _handlePush(HttpRequest request) async {
    final bodyBytes = await _collectBytes(request);
    final body = SyncProtocol.decode(bodyBytes);
    final rawRecords = body['records'];
    if (rawRecords is! List) {
      _sendJson(request.response, HttpStatus.badRequest,
          SyncProtocol.errorResponse('Missing "records" list'));
      return;
    }
    final changeset = rawRecords
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final applied = await _syncManager.applyRemoteChangeset(changeset);
    _sendJson(
        request.response, HttpStatus.ok, SyncProtocol.pushResponse(applied));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..add(SyncProtocol.encode(body));
    response.close();
  }

  Future<List<int>> _collectBytes(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  void _onServerError(Object error, StackTrace stack) {
    // Log but do not crash – sync is optional, the app runs offline-first.
    // ignore: avoid_print
    print('[LocalSyncServer] error: $error');
  }
}
