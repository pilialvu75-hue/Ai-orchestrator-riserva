/// Represents a discovered sync peer on the local network.
class SyncPeer {
  const SyncPeer({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    required this.port,
    required this.lastSeenMs,
  });

  /// Unique identifier for this device (matches [SyncManager.nodeId]).
  final String deviceId;

  /// Human-readable device name (hostname or user-assigned label).
  final String deviceName;

  /// IP address or hostname of the peer.
  final String address;

  /// TCP port on which the peer's [LocalSyncServer] is listening.
  final int port;

  /// Epoch-millisecond timestamp of the last discovery beacon from this peer.
  final int lastSeenMs;

  /// Base HTTP URL for the peer's sync endpoints.
  String get baseUrl => 'http://$address:$port';

  SyncPeer copyWith({
    String? deviceId,
    String? deviceName,
    String? address,
    int? port,
    int? lastSeenMs,
  }) =>
      SyncPeer(
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        address: address ?? this.address,
        port: port ?? this.port,
        lastSeenMs: lastSeenMs ?? this.lastSeenMs,
      );

  factory SyncPeer.fromJson(Map<String, dynamic> json) => SyncPeer(
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String? ?? 'Unknown',
        address: json['address'] as String,
        port: json['port'] as int,
        lastSeenMs: json['lastSeenMs'] as int? ??
            DateTime.now().millisecondsSinceEpoch,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'address': address,
        'port': port,
        'lastSeenMs': lastSeenMs,
      };

  @override
  String toString() =>
      'SyncPeer(deviceId=$deviceId, address=$address:$port, name=$deviceName)';

  @override
  bool operator ==(Object other) =>
      other is SyncPeer && deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}
