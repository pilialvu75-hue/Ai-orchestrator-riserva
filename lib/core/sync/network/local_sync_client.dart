import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/sync/network/sync_peer.dart';
import 'package:ai_orchestrator/core/sync/network/sync_protocol.dart';
import 'package:ai_orchestrator/core/sync/sync_manager.dart';

/// HTTP client that exchanges CRDT changesets with a [SyncPeer].
///
/// Performs a full bidirectional sync in two steps:
/// 1. **Pull** – request changes the peer has that we don't (since our maxHlc).
/// 2. **Push** – send changes we have that the peer doesn't (since peer's
///    maxHlc reported by its `/sync/info` response).
///
/// Both operations are idempotent; running them multiple times is safe.
class LocalSyncClient {
  LocalSyncClient({
    required SyncManager syncManager,
    http.Client? httpClient,
  })  : _syncManager = syncManager,
        _http = httpClient ?? http.Client();

  final SyncManager _syncManager;
  final http.Client _http;

  /// Performs a bidirectional sync with [peer].
  ///
  /// Returns a [SyncResult] describing how many records were pushed/pulled.
  /// Throws on network failure so the caller can decide on retry strategy.
  Future<SyncResult> syncWith(SyncPeer peer) async {
    // Step 1: Get peer info (includes peer's maxHlc).
    final info = await _getInfo(peer);
    final peerMaxHlc = info['maxHlc'] as String?;

    // Step 2: Pull changes from peer that we don't have yet.
    final localMaxHlc = await _syncManager.maxHlc();
    final pulled = await _pull(peer, sinceHlc: localMaxHlc);

    // Step 3: Push our changes that the peer doesn't have.
    final pushed = await _push(peer, sinceHlc: peerMaxHlc);

    return SyncResult(pushed: pushed, pulled: pulled);
  }

  /// Fetches info from the peer's `/sync/info` endpoint.
  Future<Map<String, dynamic>> fetchPeerInfo(SyncPeer peer) =>
      _getInfo(peer);

  // ── Private ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getInfo(SyncPeer peer) async {
    final uri = Uri.parse('${peer.baseUrl}${SyncProtocol.pathInfo}');
    final response = await _http.get(uri);
    _checkStatus(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<int> _pull(SyncPeer peer, {required String? sinceHlc}) async {
    final queryParams = sinceHlc != null
        ? {SyncProtocol.queryParamSince: sinceHlc}
        : <String, String>{};
    final uri = Uri.parse('${peer.baseUrl}${SyncProtocol.pathChanges}')
        .replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);
    final response = await _http.get(uri);
    _checkStatus(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rawRecords = body['records'];
    if (rawRecords is! List) return 0;
    final changeset = rawRecords
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    return _syncManager.applyRemoteChangeset(changeset);
  }

  Future<int> _push(SyncPeer peer, {required String? sinceHlc}) async {
    final records = await _syncManager.exportChangesSince(sinceHlc);
    if (records.isEmpty) return 0;
    final uri = Uri.parse('${peer.baseUrl}${SyncProtocol.pathPush}');
    final response = await _http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'records': records}),
    );
    _checkStatus(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['applied'] as int?) ?? 0;
  }

  void _checkStatus(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncClientException(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }
  }
}

/// Summary of a completed sync exchange.
class SyncResult {
  const SyncResult({required this.pushed, required this.pulled});

  /// Number of records sent to the peer.
  final int pushed;

  /// Number of records received (and applied) from the peer.
  final int pulled;

  @override
  String toString() => 'SyncResult(pushed=$pushed, pulled=$pulled)';
}

/// Exception thrown when a sync HTTP request fails.
class SyncClientException implements Exception {
  const SyncClientException(this.message);
  final String message;

  @override
  String toString() => 'SyncClientException: $message';
}
