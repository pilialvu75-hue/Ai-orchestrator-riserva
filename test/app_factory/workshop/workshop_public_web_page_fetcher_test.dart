import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

void main() {
  group('WorkshopPublicWebPageFetcher', () {
    test('fetches and cleans bounded public HTML without executing page code',
        () async {
      final client = _FakeHttpClient((request) async {
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        return _response(
          200,
          '<html><head><style>.x{display:none}</style></head>'
          '<body><h1>Guide</h1><script>steal()</script>'
          '<p>Useful &amp; bounded evidence.</p></body></html>',
          headers: const <String, String>{
            'content-type': 'text/html; charset=utf-8',
          },
        );
      });
      final fetcher = _fetcher(client);

      final result = await fetcher.fetch('https://example.com/guide');

      expect(result.isSuccess, isTrue);
      expect(result.page?.text, contains('Guide'));
      expect(result.page?.text, contains('Useful & bounded evidence.'));
      expect(result.page?.text, isNot(contains('steal()')));
      expect(result.page?.text, isNot(contains('display:none')));
      expect(client.calls, 1);
    });

    test('strict offline performs zero DNS and HTTP work', () async {
      var resolverCalls = 0;
      final client = _FakeHttpClient((_) async {
        throw AssertionError('HTTP must not run in strict offline mode');
      });
      final fetcher = WorkshopPublicWebPageFetcher(
        client: client,
        resolver: (host) async {
          resolverCalls += 1;
          return _publicResolver(host);
        },
      );

      final result = await fetcher.fetch(
        'https://example.com/private-context',
        isOffline: true,
      );

      expect(result.status, WorkshopWebPageFetchStatus.skippedOffline);
      expect(resolverCalls, 0);
      expect(client.calls, 0);
    });

    test('rejects literal loopback before HTTP', () async {
      final client = _FakeHttpClient((_) async {
        throw AssertionError('loopback HTTP must never run');
      });
      final result = await _fetcher(client).fetch('http://127.0.0.1/admin');

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'non_public_ip');
      expect(client.calls, 0);
    });

    test('rejects public-looking DNS names resolving to a private address',
        () async {
      final client = _FakeHttpClient((_) async {
        throw AssertionError('private DNS target must never be requested');
      });
      final fetcher = WorkshopPublicWebPageFetcher(
        client: client,
        resolver: (_) async => <InternetAddress>[
          InternetAddress('192.168.1.42'),
        ],
      );

      final result = await fetcher.fetch('https://example.com/admin');

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'non_public_dns_result');
      expect(client.calls, 0);
    });

    test('revalidates HTTPS redirects and blocks redirect into loopback',
        () async {
      final client = _FakeHttpClient((request) async {
        expect(request.url.host, 'example.com');
        return _response(
          302,
          '',
          headers: const <String, String>{
            'location': 'https://127.0.0.1/internal',
          },
        );
      });
      final result = await _fetcher(client).fetch(
        'https://example.com/redirect',
      );

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'non_public_ip');
      expect(client.calls, 1);
    });

    test('rejects HTTPS to HTTP redirect downgrade independently of SSRF',
        () async {
      final client = _FakeHttpClient((_) async => _response(
            302,
            '',
            headers: const <String, String>{
              'location': 'http://example.org/plaintext',
            },
          ));
      final result = await _fetcher(client).fetch(
        'https://example.com/secure',
      );

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'https_downgrade');
      expect(client.calls, 1);
    });

    test('cancels an ignored redirect body instead of draining it', () async {
      var cancelled = false;
      late StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(controller.close);

      final client = _FakeHttpClient((_) async => http.StreamedResponse(
            controller.stream,
            302,
            headers: const <String, String>{
              'location': 'https://127.0.0.1/internal',
            },
          ));
      final result = await _fetcher(client)
          .fetch('https://example.com/unbounded-redirect')
          .timeout(const Duration(seconds: 1));

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'non_public_ip');
      expect(cancelled, isTrue);
      expect(client.calls, 1);
    });

    test('rejects non-default ports before HTTP', () async {
      final client = _FakeHttpClient((_) async {
        throw AssertionError('non-default port must not be requested');
      });
      final result = await _fetcher(client).fetch(
        'https://example.com:8443/page',
      );

      expect(result.status, WorkshopWebPageFetchStatus.rejectedUrl);
      expect(result.reason, 'non_default_port');
      expect(client.calls, 0);
    });

    test('rejects binary and JavaScript response content', () async {
      final responses = <http.StreamedResponse>[
        _response(
          200,
          'not an image',
          headers: const <String, String>{'content-type': 'image/png'},
        ),
        _response(
          200,
          'fetch("https://tracker.invalid")',
          headers: const <String, String>{
            'content-type': 'text/javascript; charset=utf-8',
          },
        ),
      ];
      var index = 0;
      final client = _FakeHttpClient((_) async => responses[index++]);
      final fetcher = _fetcher(client);

      final binary = await fetcher.fetch('https://example.com/image.png');
      final script = await fetcher.fetch('https://example.com/app.js');

      expect(binary.status, WorkshopWebPageFetchStatus.unsupportedContent);
      expect(script.status, WorkshopWebPageFetchStatus.unsupportedContent);
      expect(binary.reason, 'unsupported_content_type');
      expect(script.reason, 'unsupported_content_type');
    });

    test('enforces streamed byte limit without Content-Length', () async {
      final client = _FakeHttpClient((_) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              List<int>.filled(12, 65),
              List<int>.filled(12, 66),
            ]),
            200,
            headers: const <String, String>{
              'content-type': 'text/plain; charset=utf-8',
            },
          ));
      final fetcher = WorkshopPublicWebPageFetcher(
        client: client,
        resolver: _publicResolver,
        maxBytes: 16,
      );

      final result = await fetcher.fetch('https://example.com/large.txt');

      expect(result.status, WorkshopWebPageFetchStatus.tooLarge);
      expect(result.reason, 'stream_size_limit');
    });

    test('bounds a response body that never produces data', () async {
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      final client = _FakeHttpClient((_) async => http.StreamedResponse(
            controller.stream,
            200,
            headers: const <String, String>{
              'content-type': 'text/plain; charset=utf-8',
            },
          ));
      final fetcher = WorkshopPublicWebPageFetcher(
        client: client,
        resolver: _publicResolver,
        timeout: const Duration(milliseconds: 25),
      );

      final result = await fetcher
          .fetch('https://example.com/slow.txt')
          .timeout(const Duration(seconds: 1));

      expect(result.status, WorkshopWebPageFetchStatus.unavailable);
      expect(result.reason, 'body_timeout');
    });

    test('runtime diagnostics never retain URL query data', () async {
      final log = RuntimeEventLog.instance;
      log.clear();
      addTearDown(log.clear);
      final client = _FakeHttpClient((_) async => _response(
            200,
            'Public evidence',
            headers: const <String, String>{'content-type': 'text/plain'},
          ));

      final result = await _fetcher(client).fetch(
        'https://example.com/page?user_secret=do-not-log-this',
      );

      expect(result.isSuccess, isTrue);
      final diagnostics = log.entries.map((entry) => entry.message).join('\n');
      expect(diagnostics, contains('host=example.com'));
      expect(diagnostics, isNot(contains('user_secret')));
      expect(diagnostics, isNot(contains('do-not-log-this')));
    });
  });
}

WorkshopPublicWebPageFetcher _fetcher(_FakeHttpClient client) {
  return WorkshopPublicWebPageFetcher(
    client: client,
    resolver: _publicResolver,
  );
}

Future<List<InternetAddress>> _publicResolver(String _) async =>
    <InternetAddress>[InternetAddress('93.184.216.34')];

http.StreamedResponse _response(
  int statusCode,
  String body, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    statusCode,
    headers: headers,
  );
}

final class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _handler;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls += 1;
    return _handler(request);
  }
}
