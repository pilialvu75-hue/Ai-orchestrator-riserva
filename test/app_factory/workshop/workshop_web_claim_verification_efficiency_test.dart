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
  test('does not search again when opened sources already verify the claim',
      () async {
    final search = _CountingSearchTool();
    final fetcher = WorkshopPublicWebPageFetcher(
      client: _NeverHttpClient(),
      resolver: (_) async => <InternetAddress>[InternetAddress('93.184.216.34')],
    );
    final coordinator = WorkshopWebClaimVerificationCoordinator(
      extractor: _SingleClaimExtractor(),
      corroborator: WorkshopWebClaimCorroborator(
        webSearchTool: search,
        fetcher: fetcher,
        classifier: _SupportingClassifier(),
      ),
    );

    final result = await coordinator.verify(
      request: const WorkshopRequest(
        id: 'already-verified',
        title: 'Build app',
        instruction: 'Use verified facts.',
        operation: WorkshopOperation.create,
      ),
      sourcePack: WorkshopWebSourceReadPack(
        attempted: true,
        fetchAttempts: 2,
        documents: <WorkshopWebSourceDocument>[
          _document('https://one.test/a'),
          _document('https://two.test/a'),
        ],
      ),
    );

    expect(search.calls, 0);
    expect(result.verifications, hasLength(1));
    expect(
      result.verifications.single.status,
      WorkshopWebVerificationStatus.verified,
    );
    expect(result.verifications.single.needsCorroboration, isFalse);
  });
}

WorkshopWebSourceDocument _document(String url) {
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
    text: 'SUPPORT claim evidence',
    bytesRead: 22,
  );
}

final class _SingleClaimExtractor implements WorkshopWebClaimExtractor {
  @override
  Future<List<WorkshopWebClaimCandidate>> extract({
    required WorkshopRequest request,
    required WorkshopWebSourceReadPack sourcePack,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    return const <WorkshopWebClaimCandidate>[
      WorkshopWebClaimCandidate(
        statement: 'Capability X is supported.',
        kind: WorkshopWebClaimKind.factual,
      ),
    ];
  }
}

final class _SupportingClassifier implements WorkshopWebObservationClassifier {
  @override
  Future<WorkshopWebSourceObservation?> classify({
    required WorkshopWebClaimCandidate claim,
    required WorkshopWebResearchSource source,
    required Uri finalUrl,
    required String pageText,
    required bool isOffline,
    CancellationToken? cancellationToken,
  }) async {
    return WorkshopWebSourceObservation(
      source: WorkshopWebResearchSource(
        title: source.title,
        url: finalUrl.toString(),
        snippet: source.snippet,
      ),
      role: WorkshopWebSourceRole.independentSecondary,
      supportsClaim: true,
      sourceFamily: finalUrl.host,
    );
  }
}

final class _CountingSearchTool implements Tool {
  int calls = 0;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Counting Search';

  @override
  String get description => 'Must not be called when seed evidence suffices.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    calls += 1;
    throw AssertionError('Redundant Web search should not run.');
  }
}

final class _NeverHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw AssertionError('No corroboration page should be fetched.');
  }
}
