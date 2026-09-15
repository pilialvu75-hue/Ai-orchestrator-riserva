import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

typedef WorkshopPinnedHostResolver = Future<List<InternetAddress>> Function(
  String host,
);

/// HTTP transport that resolves and validates a public host at the exact point
/// where the socket is created, then connects to the validated numeric address.
///
/// This closes the DNS-check / DNS-connect gap that would exist if a caller
/// first validated a hostname and then delegated the real connection to a
/// normal client that resolves the hostname again. `HttpClient` still receives
/// the original request URI, so HTTPS continues to use the requested host for
/// its normal TLS handling while the underlying TCP socket is pinned here.
///
/// The transport is deliberately direct-only: proxy resolution is disabled and
/// any unexpected proxy arguments fail closed.
final class WorkshopPinnedPublicHttpClient extends http.BaseClient {
  WorkshopPinnedPublicHttpClient({
    WorkshopPinnedHostResolver? resolver,
    this.connectionTimeout = const Duration(seconds: 8),
  }) : _inner = _buildClient(
          resolver ?? _defaultResolver,
          connectionTimeout,
        );

  final Duration connectionTimeout;
  final IOClient _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
  }

  static IOClient _buildClient(
    WorkshopPinnedHostResolver resolver,
    Duration timeout,
  ) {
    final dartClient = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';

    dartClient.connectionFactory = (
      Uri uri,
      String? proxyHost,
      int? proxyPort,
    ) async {
      if (proxyHost != null || proxyPort != null) {
        throw const SocketException('Proxy connections are not allowed.');
      }

      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        throw SocketException('Unsupported URI scheme: $scheme');
      }

      final host = uri.host.trim().toLowerCase();
      if (host.isEmpty || _isLocalHostName(host)) {
        throw const SocketException('Local or missing hosts are not allowed.');
      }

      final literal = InternetAddress.tryParse(host);
      final addresses = literal == null
          ? await resolver(host).timeout(timeout)
          : <InternetAddress>[literal];

      // Fail closed if DNS returns even one private/special address. A mixed
      // public/private answer must never be used as a route into the LAN.
      if (addresses.isEmpty || addresses.any((value) => !isPublicAddress(value))) {
        throw const SocketException('Destination is not a public IP address.');
      }

      final port = uri.port;
      final expectedPort = scheme == 'https'
          ? HttpClient.defaultHttpsPort
          : HttpClient.defaultHttpPort;
      if (port != expectedPort) {
        throw const SocketException('Non-default ports are not allowed.');
      }

      // HttpClient.connectionFactory expects a ConnectionTask. Socket errors
      // happen after that task is returned, so pretending to sequentially try
      // all DNS answers here would be misleading. Pin explicitly to the first
      // validated address from the shared DNS snapshot instead.
      return Socket.startConnect(addresses.first, port);
    };

    return IOClient(dartClient);
  }

  static Future<List<InternetAddress>> _defaultResolver(String host) {
    return InternetAddress.lookup(host, type: InternetAddressType.any);
  }

  static bool _isLocalHostName(String host) {
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.home.arpa');
  }

  static bool isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isPublicIpv4(bytes);
    }

    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      if (bytes.every((value) => value == 0)) return false;
      if (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) {
        return false;
      }
      if ((bytes[0] & 0xfe) == 0xfc) return false; // fc00::/7 ULA
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return false; // fe80::/10 link-local
      }
      if (bytes[0] == 0xff) return false; // multicast
      if (bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8) {
        return false; // 2001:db8::/32 documentation
      }

      final isIpv4Mapped =
          bytes.take(10).every((value) => value == 0) &&
              bytes[10] == 0xff &&
              bytes[11] == 0xff;
      if (isIpv4Mapped) {
        return _isPublicIpv4(bytes.sublist(12));
      }

      return true;
    }

    return false;
  }

  static bool _isPublicIpv4(List<int> bytes) {
    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];

    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
    if (a == 169 && b == 254) return false; // link-local
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && c == 0) return false;
    if (a == 192 && b == 0 && c == 2) return false; // TEST-NET-1
    if (a == 198 && (b == 18 || b == 19)) return false; // benchmark
    if (a == 198 && b == 51 && c == 100) return false; // TEST-NET-2
    if (a == 203 && b == 0 && c == 113) return false; // TEST-NET-3

    return true;
  }
}
