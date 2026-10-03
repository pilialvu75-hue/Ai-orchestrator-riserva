import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds each HTTP exchange used by long-running Cantiere adapters.
///
/// The timeout covers both response headers and body consumption. This matters
/// for GitHub artifact downloads too: receiving headers must not allow a stalled
/// response stream to keep a build Future alive indefinitely.
final class WorkshopBoundedHttpClient extends http.BaseClient {
  WorkshopBoundedHttpClient({
    required http.Client inner,
    required this.timeout,
  }) : _inner = inner {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be greater than zero');
    }
  }

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final streamed = await _inner.send(request).timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'HTTP ${request.method} ${request.url.host} exceeded '
            '${timeout.inMilliseconds} ms before response headers.',
          ),
        );

    // BaseClient.get/post/delete consume the returned response stream only
    // after send() has completed. Wrap that stream as well so a peer cannot
    // keep the operation alive forever after sending valid headers.
    final boundedStream = streamed.stream.timeout(
      timeout,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException(
            'HTTP ${request.method} ${request.url.host} exceeded '
            '${timeout.inMilliseconds} ms while reading response body.',
          ),
        );
        sink.close();
      },
    );

    return http.StreamedResponse(
      boundedStream,
      streamed.statusCode,
      contentLength: streamed.contentLength,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
