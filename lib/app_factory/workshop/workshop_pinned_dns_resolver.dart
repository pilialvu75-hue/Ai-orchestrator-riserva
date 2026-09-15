import 'dart:io';

typedef WorkshopDnsLookup = Future<List<InternetAddress>> Function(String host);
typedef WorkshopClock = DateTime Function();

/// Short-lived DNS snapshot shared by URL validation and socket creation.
///
/// The first lookup for a host is cached for a deliberately small interval.
/// Both the public-URL guard and [WorkshopPinnedPublicHttpClient] consume the
/// same resolver instance, so a hostile hostname cannot return a public IP for
/// validation and a private/LAN IP for the immediately following connection.
final class WorkshopPinnedDnsResolver {
  WorkshopPinnedDnsResolver({
    WorkshopDnsLookup? lookup,
    WorkshopClock? clock,
    this.ttl = const Duration(seconds: 30),
  })  : assert(ttl.inMicroseconds > 0),
        _lookup = lookup ?? _defaultLookup,
        _clock = clock ?? DateTime.now;

  final WorkshopDnsLookup _lookup;
  final WorkshopClock _clock;
  final Duration ttl;
  final Map<String, _PinnedDnsEntry> _entries = <String, _PinnedDnsEntry>{};

  Future<List<InternetAddress>> resolve(String host) async {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return const <InternetAddress>[];

    final now = _clock();
    final cached = _entries[normalized];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.addresses;
    }

    final resolved = await _lookup(normalized);
    final snapshot = List<InternetAddress>.unmodifiable(resolved);
    _entries[normalized] = _PinnedDnsEntry(
      addresses: snapshot,
      expiresAt: now.add(ttl),
    );
    return snapshot;
  }

  void clear() => _entries.clear();

  static Future<List<InternetAddress>> _defaultLookup(String host) {
    return InternetAddress.lookup(host, type: InternetAddressType.any);
  }
}

final class _PinnedDnsEntry {
  const _PinnedDnsEntry({
    required this.addresses,
    required this.expiresAt,
  });

  final List<InternetAddress> addresses;
  final DateTime expiresAt;
}
