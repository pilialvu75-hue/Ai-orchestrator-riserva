import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_public_web_page_fetcher.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_claim_verification_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_reader.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_verification.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  const request = WorkshopRequest(
    id: 'verify-request',
    title: 'Build product',
    instruction: 'Use researched evidence safely.',
    operation: WorkshopOperation.create,
  );

  test('can verify from independent already-opened documents while offline',
      () async {
    final classifier = _KeywordClassifier();
    final search = _SequenceTool(const <ToolResult>[]);
    final coordinator = _coordinator(
      extractor: _FixedExtractor(<WorkshopWebClaimCandidate>[
        const WorkshopWebClaimCandidate(
          statement: 'Capability X is supported.',
          kind: WorkshopWebClaimKind.factual,
        ),
      ]),
      classifier: classifier,
      search: search,
      client: _FakeClient((_) async => throw AssertionError('no HTTP offline')),
    );

    final result = await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://one.test/a', 'SUPPORT capability X'),
        _document('https://two.test/a', 'SUPPORT capability X'),
      ]),
      isOffline: true,
    );

    expect(search.calls, 0);
    expect(result.verifications, hasLength(1));
    expect(
      result.verifications.single.status,
      WorkshopWebVerificationStatus.verified,
    );
  });

  test('uses one independent Web page to corroborate a single seed source',
      () async {
    final search = _SequenceTool(<ToolResult>[
      _searchSuccess(<String>['https://independent.test/claim']),
    ]);
    final client = _FakeClient((request) async {
      expect(request.url.host, 'independent.test');
      return _textResponse('SUPPORT independent corroboration');
    });
    final coordinator = _coordinator(
      extractor: _FixedExtractor(<WorkshopWebClaimCandidate>[
        const WorkshopWebClaimCandidate(
          statement: 'Capability X is supported.',
          kind: WorkshopWebClaimKind.technical,
        ),
      ]),
      classifier: _KeywordClassifier(),
      search: search,
      client: client,
    );

    final result = await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://primary.test/a', 'SUPPORT primary evidence'),
      ]),
    );

    expect(search.calls, 1);
    expect(client.calls, 1);
    expect(result.verifications.single.status,
        WorkshopWebVerificationStatus.verified);
  });

  test('preserves supporting and contradicting pages as a dispute', () async {
    final search = _SequenceTool(<ToolResult>[
      _searchSuccess(<String>['https://contradict.test/claim']),
    ]);
    final coordinator = _coordinator(
      extractor: _FixedExtractor(<WorkshopWebClaimCandidate>[
        const WorkshopWebClaimCandidate(
          statement: 'Capability X is supported.',
          kind: WorkshopWebClaimKind.factual,
        ),
      ]),
      classifier: _KeywordClassifier(),
      search: search,
      client: _FakeClient(
        (_) async => _textResponse('CONTRADICT independent evidence'),
      ),
    );

    final result = await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://support.test/a', 'SUPPORT seed evidence'),
      ]),
    );

    expect(result.verifications.single.status,
        WorkshopWebVerificationStatus.disputed);
    expect(result.hasDisputes, isTrue);
  });

  test('does not refetch a corroboration result from an already-opened host',
      () async {
    final search = _SequenceTool(<ToolResult>[
      _searchSuccess(<String>[
        'https://same.test/another',
        'https://fresh.test/claim',
      ]),
    ]);
    final client = _FakeClient(
      (request) async => _textResponse('SUPPORT ${request.url.host}'),
    );
    final coordinator = _coordinator(
      extractor: _FixedExtractor(<WorkshopWebClaimCandidate>[
        const WorkshopWebClaimCandidate(
          statement: 'Capability X is supported.',
          kind: WorkshopWebClaimKind.factual,
        ),
      ]),
      classifier: _KeywordClassifier(),
      search: search,
      client: client,
    );

    await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://same.test/seed', 'SUPPORT seed evidence'),
      ]),
    );

    expect(client.requestedHosts, <String>['fresh.test']);
  });

  test('extractor failure is fail-closed and does not invent verification',
      () async {
    final coordinator = _coordinator(
      extractor: _ThrowingExtractor(),
      classifier: _KeywordClassifier(),
      search: _SequenceTool(const <ToolResult>[]),
      client: _FakeClient((_) async => throw AssertionError('no HTTP expected')),
    );

    final result = await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://one.test/a', 'SUPPORT evidence'),
      ]),
    );

    expect(result.attempted, isTrue);
    expect(result.verifications, isEmpty);
    expect(result.hasVerifiedClaims, isFalse);
  });

  test('pre-cancelled verification performs no extraction or Web work',
      () async {
    final token = CancellationToken()..cancel();
    final extractor = _FixedExtractor(<WorkshopWebClaimCandidate>[
      const WorkshopWebClaimCandidate(
        statement: 'Capability X is supported.',
        kind: WorkshopWebClaimKind.factual,
      ),
    ]);
    final search = _SequenceTool(const <ToolResult>[]);
    final coordinator = _coordinator(
      extractor: extractor,
      classifier: _KeywordClassifier(),
      search: search,
      client: _FakeClient((_) async => throw AssertionError('no HTTP expected')),
    );

    final result = await coordinator.verify(
      request: request,
      sourcePack: _sourcePack(<WorkshopWebSourceDocument>[
        _document('https://one.test/a', 'SUPPORT evidence'),
      ]),
      cancellationToken: token,
    );

    expect(result.attempted, isFalse);
    expect(extractor.calls, 0);
    expect(search.calls, 0);
  });

  test('verification prompt context preserves unresolved status explicitly', () {
    const pack = WorkshopWebVerificationPack(
      attempted: true,
      verifications: <WorkshopWebClaimVerification>[
        WorkshopWebClaimVerification(
          claim: 'Claim X',
          kind: WorkshopWebClaimKind.factual,
          status: WorkshopWebVerificationStatus.disputed,
          evidenceStrength: 0.8,
          observations: <WorkshopWebSourceObservation>[],
          needsCorroboration: true,
          reason: 'independent_evidence_conflicts',
        ),
      ],
    );

    final context = pack.toPromptContext();
    expect(context, contains('STATUS: disputed'));
    expect(context, contains('must not be silently'));
  });
}

WorkshopWebClaimVerificationCoordinator _coordinator({
  required WorkshopWebClaimExtractor extractor,
  required WorkshopWebObservationClassifier classifier,
  required Tool search,
  required _FakeClient client,
}) {
  final fetcher = WorkshopPublicWebPageFetcher(
    client: client,
    resolver: (_) async => <InternetAddress>[InternetAddress('93.184.216.34')],
  );
  return WorkshopWebClaimVerificationCoordinator(
    extractor: extractor,
    corroborator: WorkshopWebClaimCorroborator(
      webSearchTool: search,
      fetcher: fetcher,
      classifier: classifier,
      maxCorroborationPages: 2,
    ),
  );
}

WorkshopWebSourceReadPack _sourcePack(List<WorkshopWebSourceDocument> docs) {
  return WorkshopWebSourceReadPack(
    attempted: true,
    documents: docs,
    fetchAttempts: docs.length,
  );
}

WorkshopWebSourceDocument _document(String url, String text) {
  final uri = Uri.parse(url);
  return WorkshopWebSourceDocument(
    lane: WorkshopWebResearchLane.domainSources,
    source: WorkshopWebResearchSource(
      title: uri.host,
      url: url,
      snippet: 'seed',
    ),
    finalUrl: uri,
    contentType: 'text/plain',
    text: text,
    bytesRead: text.length,
  );
}

ToolResult _searchSuccess(List<String> urls) {
  return ToolResult(
    toolId: 'web_search',
    output: 'ranked results',
    metadata: <String, Object?>{
      'results': urls
          .map(
            (url) => <String, Object?>{
              'title': Uri.parse(url).host,
              'url': url,
              'snippet': 'candidate',
            },
          )
          .toList(growable: false),
    },
  );
}

http.StreamedResponse _textResponse(String body) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    200,
    headers: const <String, String>{'content-type': 'text/plain'},
  );
}

final class _FixedExtractor implements WorkshopWebClaimExtractor {
  _FixedExtractor(this.claims);

  final List<WorkshopWebClaimCandidate> claims;
  int calls = 0;

  @override
  Future<List<WorkshopWebClaimCandidate>> extract({
    required WorkshopRequest request,
    required WorkshopWebSourceReadPack sourcePack,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    calls += 1;
    return claims;
  }
}

final class _ThrowingExtractor implements WorkshopWebClaimExtractor {
  @override
  Future<List<WorkshopWebClaimCandidate>> extract({
    required WorkshopRequest request,
    required WorkshopWebSourceReadPack sourcePack,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) {
    throw StateError('malformed extraction');
  }
}

final class _KeywordClassifier implements WorkshopWebObservationClassifier {
  @override
  Future<WorkshopWebSourceObservation?> classify({
    required WorkshopWebClaimCandidate claim,
    required WorkshopWebResearchSource source,
    required Uri finalUrl,
    required String pageText,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    final upper = pageText.toUpperCase();
    final supports = upper.contains('SUPPORT');
    final contradicts = upper.contains('CONTRADICT');
    if (!supports && !contradicts) return null;

    return WorkshopWebSourceObservation(
      source: WorkshopWebResearchSource(
        title: source.title,
        url: finalUrl.toString(),
        snippet: source.snippet,
      ),
      role: finalUrl.host.contains('primary')
          ? WorkshopWebSourceRole.primary
          : WorkshopWebSourceRole.independentSecondary,
      supportsClaim: supports,
      contradictsClaim: contradicts,
      sourceFamily: finalUrl.host,
    );
  }
}

final class _SequenceTool implements Tool {
  _SequenceTool(this.results);

  final List<ToolResult> results;
  int calls = 0;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Verification Search';

  @override
  String get description => 'Deterministic verification search fixture.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final index = calls;
    calls += 1;
    if (index >= results.length) {
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'no fixture',
        metadata: <String, Object?>{'failure_reason': 'no_results'},
      );
    }
    return results[index];
  }
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
