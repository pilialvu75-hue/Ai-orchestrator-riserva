import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_reader.dart';

void main() {
  test('reads at most one successful page per research lane', () async {
    final client = _FakeClient((request) async {
      return _textResponse('content from ${request.url.host}');
    });
    final reader = _reader(client);

    final result = await reader.read(
      evidencePack: _pack(<WorkshopWebResearchEvidence>[
        _lane(
          WorkshopWebResearchLane.competitors,
          <String>['https://competitor.test/a'],
        ),
        _lane(
          WorkshopWebResearchLane.userFeedback,
          <String>['https://forum.test/a'],
        ),
        _lane(
          WorkshopWebResearchLane.domainSources,
          <String>['https://domain.test/a'],
        ),
      ]),
    );

    expect(result.documents, hasLength(3));
    expect(result.fetchAttempts, 3);
    expect(
      result.documents.map((entry) => entry.sourceHost).toSet(),
      <String>{'competitor.test', 'forum.test', 'domain.test'},
    );
  });

  test('falls back to the next ranked source when the first page fails',
      () async {
    final client = _FakeClient((request) async {
      if (request.url.host == 'broken.test') {
        return _response(503, 'unavailable');
      }
      return _textResponse('usable domain evidence');
    });
    final reader = _reader(client);

    final result = await reader.read(
      evidencePack: _pack(<WorkshopWebResearchEvidence>[
        _lane(
          WorkshopWebResearchLane.domainSources,
          <String>[
            'https://broken.test/a',
            'https://usable.test/a',
          ],
        ),
      ]),
    );

    expect(result.fetchAttempts, 2);
    expect(result.documents, hasLength(1));
    expect(result.documents.single.sourceHost, 'usable.test');
  });

  test('prefers host diversity across lanes without refetching duplicates',
      () async {
    final client = _FakeClient((request) async {
      return _textResponse('evidence ${request.url.host}');
    });
    final reader = _reader(client);

    final result = await reader.read(
      evidencePack: _pack(<WorkshopWebResearchEvidence>[
        _lane(
          WorkshopWebResearchLane.competitors,
          <String>['https://same.test/competitor'],
        ),
        _lane(
          WorkshopWebResearchLane.userFeedback,
          <String>[
            'https://same.test/forum',
            'https://different.test/forum',
          ],
        ),
      ]),
    );

    expect(result.documents, hasLength(2));
    expect(
      result.documents.map((entry) => entry.sourceHost).toList(),
      <String>['same.test', 'different.test'],
    );
    expect(client.requestedHosts, <String>['same.test', 'different.test']);
  });

  test('strict offline performs zero page fetch work', () async {
    final client = _FakeClient((_) async {
      throw AssertionError('HTTP must not run in strict offline mode');
    });
    final reader = _reader(client);

    final result = await reader.read(
      evidencePack: _pack(<WorkshopWebResearchEvidence>[
        _lane(
          WorkshopWebResearchLane.domainSources,
          <String>['https://domain.test/a'],
        ),
      ]),
      isOffline: true,
    );

    expect(result.attempted, isFalse);
    expect(result.documents, isEmpty);
    expect(result.fetchAttempts, 0);
    expect(client.calls, 0);
  });

  test('keeps page-level evidence inside the aggregate character budget',
      () async {
    final client = _FakeClient((request) async {
      final payload = List<String>.filled(200, 'x').join();
      return _textResponse('${request.url.host} $payload');
    });
    final reader = WorkshopWebSourceReader(
      fetcher: _fetcher(client),
      maxCharsPerDocument: 80,
      maxTotalChars: 150,
    );

    final result = await reader.read(
      evidencePack: _pack(<WorkshopWebResearchEvidence>[
        _lane(
          WorkshopWebResearchLane.competitors,
          <String>['https://one.test/a'],
        ),
        _lane(
          WorkshopWebResearchLane.userFeedback,
          <String>['https://two.test/a'],
        ),
        _lane(
          WorkshopWebResearchLane.domainSources,
          <String>['https://three.test/a'],
        ),
      ]),
    );

    expect(result.totalChars, lessThanOrEqualTo(150));
    expect(result.documents.first.text.length, lessThanOrEqualTo(80));
  });
}

WorkshopWebSourceReader _reader(_FakeClient client) {
  return WorkshopWebSourceReader(fetcher: _fetcher(client));
}

WorkshopPublicWebPageFetcher _fetcher(_FakeClient client) {
  return WorkshopPublicWebPageFetcher(
    client: client,
    resolver: (_) async => <InternetAddress>[InternetAddress('93.184.216.34')],
  );
}

WorkshopWebEvidencePack _pack(List<WorkshopWebResearchEvidence> evidence) {
  return WorkshopWebEvidencePack(
    attempted: true,
    evidence: evidence,
  );
}

WorkshopWebResearchEvidence _lane(
  WorkshopWebResearchLane lane,
  List<String> urls,
) {
  return WorkshopWebResearchEvidence(
    lane: lane,
    query: 'query-${lane.name}',
    output: 'ranked evidence',
    success: true,
    sources: urls
        .map(
          (url) => WorkshopWebResearchSource(
            title: 'Source',
            url: url,
            snippet: 'Snippet',
          ),
        )
        .toList(growable: false),
  );
}

http.StreamedResponse _textResponse(String body) {
  return _response(
    200,
    body,
    headers: const <String, String>{'content-type': 'text/plain'},
  );
}

http.StreamedResponse _response(
  int status,
  String body, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: headers,
  );
}

final class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  int calls = 0;
  final List<String> requestedHosts = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls += 1;
    requestedHosts.add(request.url.host);
    return handler(request);
  }
}
