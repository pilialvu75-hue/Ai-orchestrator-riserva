import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/sync/network/sync_peer.dart';

/// UDP-based LAN peer discovery for the local-first sync layer.
///
/// [SyncDiscoveryService] broadcasts a compact JSON beacon on the local
/// subnet every [AppConstants.syncDiscoveryInterval] and listens for beacons
/// from other devices.  Discovered peers are exposed via [onPeerDiscovered].
///
/// Uses UDP multicast so beacons reach all devices on the same Wi-Fi/LAN
/// segment without knowing peer IP addresses in advance.
///
/// **Privacy note**: Beacons contain only the device ID, device name, and sync
/// port.  No chat data, credentials, or user content is ever broadcast.
class SyncDiscoveryService {
  SyncDiscoveryService({
    required String deviceId,
    required String deviceName,
    required int syncPort,
  })  : _deviceId = deviceId,
        _deviceName = deviceName,
        _syncPort = syncPort;

  final String _deviceId;
  final String _deviceName;
  final int _syncPort;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  final _peers = <String, SyncPeer>{};
  final _controller = StreamController<SyncPeer>.broadcast();

  bool get isRunning => _socket != null;

  /// Stream of discovered (or refreshed) peers.
  Stream<SyncPeer> get onPeerDiscovered => _controller.stream;

  /// All currently known live peers (seen within the last 60 seconds).
  List<SyncPeer> get activePeers {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 60000;
    return _peers.values
        .where((p) => p.lastSeenMs >= cutoff)
        .toList(growable: false);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Starts broadcasting and listening for peer beacons.
  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.syncDiscoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onData, onError: _onError);
      _broadcastTimer = Timer.periodic(
        AppConstants.syncDiscoveryInterval,
        (_) => _broadcast(),
      );
      // Immediately send one beacon on start.
      _broadcast();
    } catch (e) {
      // Discovery is optional; if binding fails the app continues without sync.
      // Log to aid troubleshooting (e.g. port in use, missing permissions).
      stderr.writeln('[SyncDiscoveryService] could not bind discovery socket: $e');
      _socket = null;
    }
  }

  /// Stops broadcasting and closes the socket.
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _socket?.close();
    _socket = null;
  }

  /// Disposes the service, releasing all resources.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _broadcast() {
    if (_socket == null) return;
    final payload = jsonEncode({
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'port': _syncPort,
    });
    final bytes = utf8.encode(payload);
    try {
      _socket!.send(
        bytes,
        InternetAddress(AppConstants.syncDiscoveryMulticast),
        AppConstants.syncDiscoveryPort,
      );
    } catch (e) {
      // Network not available or interface error; log for debugging.
      stderr.writeln('[SyncDiscoveryService] broadcast failed: $e');
    }
  }

  void _onData(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      final deviceId = json['deviceId'] as String?;
      if (deviceId == null || deviceId == _deviceId) return; // Ignore self
      final peer = SyncPeer(
        deviceId: deviceId,
        deviceName: json['deviceName'] as String? ?? 'Unknown',
        address: datagram.address.address,
        port: json['port'] as int? ?? AppConstants.syncDefaultPort,
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      );
      _peers[deviceId] = peer;
      _controller.add(peer);
    } catch (_) {
      // Malformed beacon; ignore.
    }
  }

  void _onError(Object error) {
    // Log but do not crash – discovery is best-effort.
    stderr.writeln('[SyncDiscoveryService] error: $error');
  }
}
