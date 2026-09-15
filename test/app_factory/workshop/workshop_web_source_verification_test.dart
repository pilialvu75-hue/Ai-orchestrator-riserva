import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_source_verification.dart';

void main() {
  const policy = WorkshopWebVerificationPolicy();

  test('verifies a factual claim only after independent source families agree', () {
    final result = policy.evaluate(
      claim: 'The platform supports capability X.',
      kind: WorkshopWebClaimKind.factual,
      observations: <WorkshopWebSourceObservation>[
        _support('https://docs.example.com/x', family: 'example'),
        _support('https://independent.test/x', family: 'independent'),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.verified);
    expect(result.needsCorroboration, isFalse);
    expect(result.canDriveFactualImplementation, isTrue);
  });

  test('multiple pages from one publisher do not satisfy independence', () {
    final result = policy.evaluate(
      claim: 'The platform supports capability X.',
      kind: WorkshopWebClaimKind.technical,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://news.example.com/x',
          family: 'example-publisher',
        ),
        _support(
          'https://blog.example.com/x',
          family: 'example-publisher',
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.supported);
    expect(result.needsCorroboration, isTrue);
    expect(result.canDriveFactualImplementation, isFalse);
  });

  test('preserves conflicting factual evidence as disputed', () {
    final result = policy.evaluate(
      claim: 'Feature X is supported on the target platform.',
      kind: WorkshopWebClaimKind.technical,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://official.example.com/x',
          role: WorkshopWebSourceRole.primary,
          family: 'official',
        ),
        _contradict(
          'https://independent.test/x',
          family: 'independent',
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.disputed);
    expect(result.needsCorroboration, isTrue);
    expect(result.canDriveFactualImplementation, isFalse);
  });

  test('security claims require primary plus independent corroboration', () {
    final primaryOnly = policy.evaluate(
      claim: 'Configuration X prevents the vulnerability.',
      kind: WorkshopWebClaimKind.safetySecurity,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://security.example.com/advisory',
          role: WorkshopWebSourceRole.primary,
          family: 'vendor',
        ),
      ],
    );
    expect(primaryOnly.status, WorkshopWebVerificationStatus.supported);
    expect(primaryOnly.needsCorroboration, isTrue);

    final corroborated = policy.evaluate(
      claim: 'Configuration X prevents the vulnerability.',
      kind: WorkshopWebClaimKind.safetySecurity,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://security.example.com/advisory',
          role: WorkshopWebSourceRole.primary,
          family: 'vendor',
        ),
        _support(
          'https://research.test/advisory',
          role: WorkshopWebSourceRole.independentSecondary,
          family: 'researcher',
        ),
      ],
    );
    expect(corroborated.status, WorkshopWebVerificationStatus.verified);
    expect(corroborated.needsCorroboration, isFalse);
  });

  test('licensing cannot be verified by third-party consensus', () {
    final thirdPartyConsensus = policy.evaluate(
      claim: 'The material can be reused verbatim.',
      kind: WorkshopWebClaimKind.legalLicensing,
      observations: <WorkshopWebSourceObservation>[
        _support('https://blog-one.test/license', family: 'one'),
        _support('https://blog-two.test/license', family: 'two'),
      ],
    );

    expect(
      thirdPartyConsensus.status,
      WorkshopWebVerificationStatus.referenceOnly,
    );
    expect(thirdPartyConsensus.needsCorroboration, isTrue);
    expect(thirdPartyConsensus.canDriveFactualImplementation, isFalse);
  });

  test('explicit reuse terms at the primary source verify licensing', () {
    final result = policy.evaluate(
      claim: 'The material can be reused under the stated licence.',
      kind: WorkshopWebClaimKind.legalLicensing,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://owner.example/license',
          role: WorkshopWebSourceRole.primary,
          family: 'owner',
          explicitReuseTerms: true,
          freshness: WorkshopWebSourceFreshness.current,
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.verified);
    expect(result.needsCorroboration, isFalse);
  });

  test('stale evidence cannot verify a freshness-sensitive claim', () {
    final result = policy.evaluate(
      claim: 'Version X is currently supported.',
      kind: WorkshopWebClaimKind.technical,
      requiresFreshness: true,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://docs.example/old',
          role: WorkshopWebSourceRole.primary,
          freshness: WorkshopWebSourceFreshness.stale,
        ),
      ],
    );

    expect(
      result.status,
      WorkshopWebVerificationStatus.insufficientEvidence,
    );
    expect(result.reason, 'no_current_supporting_evidence');
  });

  test('one subjective source is reference-only, not a universal fact', () {
    final result = policy.evaluate(
      claim: 'Users prefer feature X.',
      kind: WorkshopWebClaimKind.subjectiveSignal,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://forum.example/thread',
          role: WorkshopWebSourceRole.community,
          family: 'forum-example',
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.referenceOnly);
    expect(result.canDriveFactualImplementation, isFalse);
  });

  test('diverse subjective sources produce a supported signal, not a fact', () {
    final result = policy.evaluate(
      claim: 'Users prefer feature X.',
      kind: WorkshopWebClaimKind.subjectiveSignal,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://forum-one.test/thread',
          role: WorkshopWebSourceRole.community,
          family: 'community-one',
        ),
        _support(
          'https://forum-two.test/thread',
          role: WorkshopWebSourceRole.community,
          family: 'community-two',
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.supported);
    expect(result.needsCorroboration, isFalse);
    expect(result.canDriveFactualImplementation, isFalse);
  });

  test('opposing user opinions remain a mixed signal', () {
    final result = policy.evaluate(
      claim: 'Users prefer feature X.',
      kind: WorkshopWebClaimKind.subjectiveSignal,
      observations: <WorkshopWebSourceObservation>[
        _support(
          'https://forum-one.test/thread',
          role: WorkshopWebSourceRole.community,
          family: 'community-one',
        ),
        _contradict(
          'https://forum-two.test/thread',
          role: WorkshopWebSourceRole.community,
          family: 'community-two',
        ),
      ],
    );

    expect(result.status, WorkshopWebVerificationStatus.mixed);
    expect(result.reason, 'mixed_user_signal_preserved');
  });
}

WorkshopWebSourceObservation _support(
  String url, {
  WorkshopWebSourceRole role = WorkshopWebSourceRole.independentSecondary,
  String? family,
  bool explicitReuseTerms = false,
  WorkshopWebSourceFreshness freshness = WorkshopWebSourceFreshness.unknown,
}) {
  return WorkshopWebSourceObservation(
    source: WorkshopWebResearchSource(
      title: 'Source',
      url: url,
      snippet: 'Evidence',
    ),
    role: role,
    supportsClaim: true,
    sourceFamily: family,
    explicitReuseTerms: explicitReuseTerms,
    freshness: freshness,
  );
}

WorkshopWebSourceObservation _contradict(
  String url, {
  WorkshopWebSourceRole role = WorkshopWebSourceRole.independentSecondary,
  String? family,
  WorkshopWebSourceFreshness freshness = WorkshopWebSourceFreshness.unknown,
}) {
  return WorkshopWebSourceObservation(
    source: WorkshopWebResearchSource(
      title: 'Source',
      url: url,
      snippet: 'Contradicting evidence',
    ),
    role: role,
    contradictsClaim: true,
    sourceFamily: family,
    freshness: freshness,
  );
}
