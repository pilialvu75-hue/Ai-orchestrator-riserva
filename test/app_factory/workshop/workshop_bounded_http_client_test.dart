import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_bounded_http_client.dart';

void main() {
  test('rejects a non-positive request timeout', () {
    expect(
      () => WorkshopBoundedHttpClient(
        inner: _ImmediateClient(),
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test('bounds a GitHub request that never returns response headers', () async {
    final inner = _NeverHeadersClient();
    final client = WorkshopBoundedHttpClient(
      inner: inner,
      timeout: const Duration(milliseconds: 20),
    );

    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.get(Uri.parse('https://api.github.com/repos/test/repo')),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('before response headers'),
        ),
      ),
    );
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    client.close();
  });

  test('bounds a response body that stalls after valid headers', () async {
    final inner = _NeverBodyClient();
    final client = WorkshopBoundedHttpClient(
      inner: inner,
      timeout: const Duration(milliseconds: 20),
    );

    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.get(Uri.parse('https://api.github.com/artifact.zip')),
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('while reading response body'),
        ),
      ),
    );
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    client.close();
  });

  test('preserves successful responses unchanged', () async {
    final client = WorkshopBoundedHttpClient(
      inner: _ImmediateClient(),
      timeout: const Duration(seconds: 1),
    );

    final response = await client.get(
      Uri.parse('https://api.github.com/repos/test/repo'),
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), <String, Object?>{'private': true});
    client.close();
  });
}

final class _NeverHeadersClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _completer =
      Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _completer.future;
}

final class _NeverBodyClient extends http.BaseClient {
  final StreamController<List<int>> _body = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      _body.stream,
      200,
      request: request,
    );
  }

  @override
  void close() {
    unawaited(_body.close());
  }
}

final class _ImmediateClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode('{"private":true}');
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
      request: request,
      headers: const <String, String>{
        'content-type': 'application/json',
      },
    );
  }
}
