import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_claim_verification_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_reader.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_verification.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_verification_inference_adapter.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';

void main() {
  const request = WorkshopRequest(
    id: 'adapter-request',
    title: 'Build a useful app',
    instruction: 'Use verified Web evidence when relevant.',
    operation: WorkshopOperation.create,
  );

  test('extracts only strict claim protocol lines', () async {
    final completion = _Completion(<String>[
      'CLAIM\ttechnical\tcurrent\tVersion X is supported.\n'
          'CLAIM\tsubjectiveSignal\tstable\tUsers value offline access.',
    ]);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );

    final claims = await adapter.extract(
      request: request,
      sourcePack: _sourcePack(),
      isOffline: false,
    );

    expect(claims, hasLength(2));
    expect(claims[0].kind, WorkshopWebClaimKind.technical);
    expect(claims[0].requiresFreshness, isTrue);
    expect(claims[1].kind, WorkshopWebClaimKind.subjectiveSignal);
    expect(claims[1].requiresFreshness, isFalse);
    expect(completion.requests.single.maxTokens, 320);
    expect(completion.requests.single.temperature, 0.1);
  });

  test('rejects extraction when model adds prose or malformed protocol',
      () async {
    final completion = _Completion(<String>[
      'Here are the claims:\n'
          'CLAIM\tfactual\tstable\tClaim X',
    ]);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );

    final claims = await adapter.extract(
      request: request,
      sourcePack: _sourcePack(),
      isOffline: false,
    );

    expect(claims, isEmpty);
  });

  test('rejects oversized or unknown claim fields instead of guessing',
      () async {
    final completion = _Completion(<String>[
      'CLAIM\tunknownKind\tstable\tClaim X',
      'CLAIM\tfactual\tstable\t${List<String>.filled(400, 'x').join()}',
    ]);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );

    final first = await adapter.extract(
      request: request,
      sourcePack: _sourcePack(),
      isOffline: false,
    );
    final second = await adapter.extract(
      request: request,
      sourcePack: _sourcePack(),
      isOffline: false,
    );

    expect(first, isEmpty);
    expect(second, isEmpty);
  });

  test('classifies a strict observation without deciding verification',
      () async {
    final completion = _Completion(<String>[
      'OBS\tsupport\tprimary\tcurrent\treuse_no',
    ]);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );

    final observation = await adapter.classify(
      claim: const WorkshopWebClaimCandidate(
        statement: 'Feature X is supported.',
        kind: WorkshopWebClaimKind.technical,
        requiresFreshness: true,
      ),
      source: const WorkshopWebResearchSource(
        title: 'Official docs',
        url: 'https://docs.example.com/page?secret=do-not-leak',
        snippet: 'Snippet',
      ),
      finalUrl: Uri.parse(
        'https://docs.example.com/page?secret=do-not-leak',
      ),
      pageText: 'The documentation says Feature X is supported.',
      isOffline: false,
    );

    expect(observation, isNotNull);
    expect(observation!.supportsClaim, isTrue);
    expect(observation.contradictsClaim, isFalse);
    expect(observation.role, WorkshopWebSourceRole.primary);
    expect(observation.freshness, WorkshopWebSourceFreshness.current);
    expect(observation.explicitReuseTerms, isFalse);
    expect(observation.independenceFamily, 'example.com');

    final prompt = completion.requests.single.prompt;
    expect(prompt, contains('https://docs.example.com/page'));
    expect(prompt, isNot(contains('secret=do-not-leak')));
    expect(prompt, contains('Do not decide whether the claim is true'));
  });

  test('unclear, multiline and malformed observations fail closed', () async {
    final completion = _Completion(<String>[
      'OBS\tunclear\tunknown\tunknown\treuse_no',
      'OBS\tsupport\tprimary\tcurrent\treuse_no\nextra prose',
      'OBS\tsupport\tprimary\tcurrent\tmaybe',
    ]);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );
    final claim = const WorkshopWebClaimCandidate(
      statement: 'Claim X',
      kind: WorkshopWebClaimKind.factual,
    );
    const source = WorkshopWebResearchSource(
      title: 'Source',
      url: 'https://example.com/a',
      snippet: 'Snippet',
    );
    final url = Uri.parse('https://example.com/a');

    expect(
      await adapter.classify(
        claim: claim,
        source: source,
        finalUrl: url,
        pageText: 'Ambiguous evidence',
        isOffline: false,
      ),
      isNull,
    );
    expect(
      await adapter.classify(
        claim: claim,
        source: source,
        finalUrl: url,
        pageText: 'Evidence',
        isOffline: false,
      ),
      isNull,
    );
    expect(
      await adapter.classify(
        claim: claim,
        source: source,
        finalUrl: url,
        pageText: 'Evidence',
        isOffline: false,
      ),
      isNull,
    );
  });

  test('failed inference and cancelled work yield no semantic evidence',
      () async {
    final completion = _Completion(<String>['ignored'], successful: false);
    final adapter = WorkshopWebVerificationInferenceAdapter(
      completion: completion.call,
    );

    final claims = await adapter.extract(
      request: request,
      sourcePack: _sourcePack(),
      isOffline: false,
    );

    expect(claims, isEmpty);
  });
}

WorkshopWebSourceReadPack _sourcePack() {
  const source = WorkshopWebResearchSource(
    title: 'Example source',
    url: 'https://example.com/source',
    snippet: 'Snippet',
  );
  return WorkshopWebSourceReadPack(
    attempted: true,
    fetchAttempts: 1,
    documents: <WorkshopWebSourceDocument>[
      WorkshopWebSourceDocument(
        lane: WorkshopWebResearchLane.domainSources,
        source: source,
        finalUrl: Uri.parse('https://example.com/source'),
        contentType: 'text/plain',
        text: 'Source material for verification.',
        bytesRead: 33,
      ),
    ],
  );
}

final class _Completion {
  _Completion(this.outputs, {this.successful = true});

  final List<String> outputs;
  final bool successful;
  final List<WorkshopVerificationInferencePrompt> requests =
      <WorkshopVerificationInferencePrompt>[];
  int calls = 0;

  Future<WorkshopInferenceResult> call(
    WorkshopVerificationInferencePrompt request,
    dynamic cancellationToken,
  ) async {
    requests.add(request);
    final index = calls++;
    final text = index < outputs.length ? outputs[index] : '';
    return WorkshopInferenceResult(
      text: text,
      terminalState: successful
          ? InferenceTerminalState.success
          : InferenceTerminalState.error,
      errorMessage: successful ? null : 'simulated failure',
    );
  }
}
