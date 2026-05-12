import 'dart:convert';

/// Wire protocol for the local P2P sync HTTP API.
///
/// All messages are JSON-encoded UTF-8 strings exchanged over HTTP on the
/// local network (Wi-Fi / USB tethering).  No data leaves the device's local
/// subnet unless the user explicitly configures a remote relay.
///
/// ## Endpoints exposed by [LocalSyncServer]
///
/// | Method | Path | Description |
/// |--------|------|-------------|
/// | `GET`  | `/sync/info` | Returns [SyncInfoResponse] |
/// | `GET`  | `/sync/changes?since=<hlc>` | Returns [ChangesResponse] |
/// | `POST` | `/sync/push` | Accepts [PushRequest], returns [PushResponse] |
///
/// All responses include `"ok": true` on success, `"ok": false` with an
/// `"error"` field on failure.
abstract class SyncProtocol {
  SyncProtocol._();

  // ── Path constants ─────────────────────────────────────────────────────────

  static const String pathInfo = '/sync/info';
  static const String pathChanges = '/sync/changes';
  static const String pathPush = '/sync/push';
  static const String queryParamSince = 'since';

  // ── Serialisation helpers ─────────────────────────────────────────────────

  /// Encodes a response map to a UTF-8 JSON byte list.
  static List<int> encode(Map<String, dynamic> body) =>
      utf8.encode(jsonEncode(body));

  /// Decodes a JSON body from a UTF-8 byte list.
  static Map<String, dynamic> decode(List<int> bytes) =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  // ── Request / Response builders ───────────────────────────────────────────

  /// Builds a `/sync/info` response.
  static Map<String, dynamic> infoResponse({
    required String deviceId,
    required String deviceName,
    required String? maxHlc,
  }) =>
      {
        'ok': true,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'maxHlc': maxHlc,
      };

  /// Builds a `/sync/changes` response.
  static Map<String, dynamic> changesResponse(
    List<Map<String, dynamic>> records,
  ) =>
      {'ok': true, 'records': records};

  /// Builds a `/sync/push` response.
  static Map<String, dynamic> pushResponse(int applied) =>
      {'ok': true, 'applied': applied};

  /// Builds a generic error response.
  static Map<String, dynamic> errorResponse(String message) =>
      {'ok': false, 'error': message};
}
