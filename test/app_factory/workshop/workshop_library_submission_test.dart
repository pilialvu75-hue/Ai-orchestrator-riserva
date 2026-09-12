import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLibrarySubmissionGate', () {
    const gate = WorkshopLibrarySubmissionGate();

    test('builds untrusted Library intake manifest for verified Cantiere asset', () {
      final decision = gate.evaluate(_validEvidence());

      expect(decision.accepted, isTrue);
      expect(decision.reasons, isEmpty);
      final submission = decision.submission!;
      expect(submission.pin, 'voice.turn_taking@1.2.0');
      expect(
        submission.manifestPath,
        'intake/voice.turn_taking/1.2.0/manifest.json',
      );
      expect(submission.manifest['status'], 'discovered');
      expect(submission.manifest['kind'], 'integration_bundle');

      final provenance = submission.manifest['provenance']! as Map<String, Object?>;
      expect(provenance['origin'], 'cantiere');
      expect(provenance['source_project_id'], 'project-voice');
      expect(provenance['source_task_id'], 'task-turn-taking');
      expect(provenance['license'], 'Apache-2.0');

      final connector = submission.manifest['connector']! as Map<String, Object?>;
      expect(connector['standard'], 'ai-orchestrator-lego');
      expect(connector['standard_version'], '1.0.0');
      final provides = connector['provides']! as List<Object?>;
      expect(provides, hasLength(1));
      expect(
        (provides.single! as Map<String, Object?>)['contract_id'],
        'voice.turn_taking.v1',
      );
    });

    test('never self-certifies a Cantiere submission', () {
      final submission = gate.evaluate(_validEvidence()).submission!;
      expect(submission.manifest['status'], isNot('tested'));
      expect(submission.manifest['status'], isNot('certified'));
      expect(submission.manifest['status'], 'discovered');
    });

    test('blocks low validation and failed tests', () {
      final decision = gate.evaluate(
        _validEvidence(validationScore: 0.79, testsPassed: false),
      );

      expect(decision.accepted, isFalse);
      expect(decision.submission, isNull);
      expect(decision.reasons, contains('validation-score-below-threshold'));
      expect(decision.reasons, contains('tests-not-passed'));
    });

    test('blocks unreviewed or known-vulnerable output from automatic intake', () {
      final decision = gate.evaluate(
        _validEvidence(
          securityReviewed: false,
          knownVulnerabilities: 2,
        ),
      );

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('security-not-reviewed'));
      expect(
        decision.reasons,
        contains('known-vulnerabilities-require-manual-review'),
      );
    });

    test('requires immutable semver and payload sha256', () {
      final decision = gate.evaluate(
        _validEvidence(
          version: 'latest',
          payload: const WorkshopLibraryPayloadEvidence(
            type: WorkshopLibraryPayloadType.repositoryPath,
            path: 'payload/',
            sha256: 'not-a-digest',
          ),
        ),
      );

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('invalid-semver-version'));
      expect(decision.reasons, contains('invalid-payload-sha256'));
    });

    test('requires declared capability to match Lego provides', () {
      final decision = gate.evaluate(
        _validEvidence(capabilities: const <String>['voice.tts']),
      );

      expect(decision.accepted, isFalse);
      expect(
        decision.reasons,
        contains('lego-provide-capability-not-declared:voice.turn_taking'),
      );
    });

    test('rejects adapter target not declared by the asset', () {
      final decision = gate.evaluate(
        _validEvidence(
          connector: const WorkshopLibraryConnectorEvidence(
            provides: <WorkshopLibraryLegoProvide>[
              WorkshopLibraryLegoProvide(
                capabilityId: 'voice.turn_taking',
                contractId: 'voice.turn_taking.v1',
                contractVersion: '1.0',
              ),
            ],
            adapters: <WorkshopLibraryLegoAdapter>[
              WorkshopLibraryLegoAdapter(
                target: 'ios',
                entryPath: 'lib/voice_adapter.dart',
              ),
            ],
          ),
        ),
      );

      expect(decision.accepted, isFalse);
      expect(
        decision.reasons,
        contains('lego-adapter-target-not-declared:ios'),
      );
    });

    test('rejects unsafe payload and entry paths', () {
      final decision = gate.evaluate(
        _validEvidence(
          entryPaths: const <String>['../outside.dart'],
          payload: const WorkshopLibraryPayloadEvidence(
            type: WorkshopLibraryPayloadType.repositoryPath,
            path: '../payload',
            sha256: _digest,
          ),
        ),
      );

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('invalid-payload-path'));
      expect(decision.reasons, contains('invalid-entry-path:../outside.dart'));
    });

    test('upstream reference requires immutable upstream coordinates', () {
      final decision = gate.evaluate(
        _validEvidence(
          payload: const WorkshopLibraryPayloadEvidence(
            type: WorkshopLibraryPayloadType.upstreamReference,
            sha256: _digest,
            upstreamRepository: 'https://example.invalid/repo',
          ),
        ),
      );

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('incomplete-upstream-reference'));
    });

    test('rejects duplicate dependencies and Lego provides', () {
      final decision = gate.evaluate(
        _validEvidence(
          dependencies: const <WorkshopLibraryDependency>[
            WorkshopLibraryDependency(name: 'dio', version: '^5.0.0'),
            WorkshopLibraryDependency(name: 'DIO', version: '^5.0.0'),
          ],
          connector: const WorkshopLibraryConnectorEvidence(
            provides: <WorkshopLibraryLegoProvide>[
              WorkshopLibraryLegoProvide(
                capabilityId: 'voice.turn_taking',
                contractId: 'voice.turn_taking.v1',
              ),
              WorkshopLibraryLegoProvide(
                capabilityId: 'voice.turn_taking',
                contractId: 'voice.turn_taking.v1',
              ),
            ],
          ),
        ),
      );

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('duplicate-dependency:DIO'));
      expect(
        decision.reasons,
        contains('duplicate-lego-provide:voice.turn_taking|voice.turn_taking.v1'),
      );
    });

    test('requires a stable evidence timestamp instead of using current time', () {
      final evidence = _validEvidence(
        generatedAt: null,
        validatedAt: null,
        securityReviewedAt: null,
      );
      final decision = gate.evaluate(evidence);

      expect(decision.accepted, isFalse);
      expect(decision.reasons, contains('missing-evidence-timestamp'));
    });

    test('output is deterministic when evidence timestamps are provided', () {
      final first = gate.evaluate(_validEvidence()).submission!;
      final second = gate.evaluate(_validEvidence()).submission!;
      expect(first.toJson(), second.toJson());
    });

    test('normalizes and sorts set-like manifest fields', () {
      final submission = gate
          .evaluate(
            _validEvidence(
              tags: const <String>['voice', 'stable', 'voice', ''],
              platforms: const <String>['windows', 'android', 'android'],
              languages: const <String>['dart', 'cpp', 'dart'],
              connector: const WorkshopLibraryConnectorEvidence(
                provides: <WorkshopLibraryLegoProvide>[
                  WorkshopLibraryLegoProvide(
                    capabilityId: 'voice.turn_taking',
                    contractId: 'voice.turn_taking.v1',
                    contractVersion: '1.0',
                  ),
                ],
                adapters: <WorkshopLibraryLegoAdapter>[
                  WorkshopLibraryLegoAdapter(
                    target: 'android',
                    entryPath: 'lib/voice_turn_taking.dart',
                  ),
                  WorkshopLibraryLegoAdapter(
                    target: 'windows',
                    entryPath: 'lib/voice_turn_taking.dart',
                  ),
                ],
              ),
            ),
          )
          .submission!;

      expect(submission.manifest['tags'], <String>['stable', 'voice']);
      expect(submission.manifest['platforms'], <String>['android', 'windows']);
      expect(submission.manifest['languages'], <String>['cpp', 'dart']);
    });
  });
}

const String _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

WorkshopLibraryCaptureEvidence _validEvidence({
  String version = '1.2.0',
  List<String> capabilities = const <String>['voice.turn_taking'],
  List<String> platforms = const <String>['android'],
  List<String> tags = const <String>['voice'],
  List<String> languages = const <String>['dart'],
  List<String> entryPaths = const <String>['lib/voice_turn_taking.dart'],
  List<WorkshopLibraryDependency> dependencies =
      const <WorkshopLibraryDependency>[],
  double validationScore = 0.96,
  bool testsPassed = true,
  bool securityReviewed = true,
  int knownVulnerabilities = 0,
  WorkshopLibraryConnectorEvidence connector =
      const WorkshopLibraryConnectorEvidence(
    provides: <WorkshopLibraryLegoProvide>[
      WorkshopLibraryLegoProvide(
        capabilityId: 'voice.turn_taking',
        contractId: 'voice.turn_taking.v1',
        contractVersion: '1.0',
      ),
    ],
    requires: <WorkshopLibraryLegoRequire>[
      WorkshopLibraryLegoRequire(
        capabilityId: 'voice.stt',
        contractId: 'voice.stt.v1',
      ),
    ],
    integrationMode: WorkshopLibraryIntegrationMode.adapter,
    adapters: <WorkshopLibraryLegoAdapter>[
      WorkshopLibraryLegoAdapter(
        target: 'android',
        entryPath: 'lib/voice_turn_taking.dart',
      ),
    ],
    healthcheckType: 'test',
    healthcheckPath: 'test/voice_turn_taking_test.dart',
  ),
  WorkshopLibraryPayloadEvidence payload =
      const WorkshopLibraryPayloadEvidence(
    type: WorkshopLibraryPayloadType.repositoryPath,
    path: 'payload/',
    sha256: _digest,
  ),
  DateTime? generatedAt = const _DefaultDateTimeMarker(),
  DateTime? validatedAt = const _DefaultDateTimeMarker(),
  DateTime? securityReviewedAt = const _DefaultDateTimeMarker(),
}) {
  DateTime? resolve(DateTime? value) => value is _DefaultDateTimeMarker
      ? DateTime.utc(2026, 9, 12, 15)
      : value;

  return WorkshopLibraryCaptureEvidence(
    assetId: 'voice.turn_taking',
    name: 'Voice Turn Taking',
    version: version,
    kind: WorkshopLibraryAssetKind.integrationBundle,
    description: 'Reusable voice turn-taking adapter.',
    capabilities: capabilities,
    platforms: platforms,
    sourceProjectId: 'project-voice',
    sourceTaskId: 'task-turn-taking',
    license: 'Apache-2.0',
    validationScore: validationScore,
    testsPassed: testsPassed,
    testReport: 'reports/voice-tests.json',
    validatedAt: resolve(validatedAt),
    validatedOn: const <String>['android'],
    securityReviewed: securityReviewed,
    securityReviewedAt: resolve(securityReviewedAt),
    knownVulnerabilities: knownVulnerabilities,
    sbom: 'reports/sbom.spdx.json',
    integrationEffort: WorkshopLibrarySubmissionIntegrationEffort.low,
    adaptationAllowed: true,
    knownConstraints: const <String>['Microphone permission required'],
    connector: connector,
    payload: payload,
    tags: tags,
    languages: languages,
    frameworks: const <String>['flutter'],
    entryPaths: entryPaths,
    dependencies: dependencies,
    generatedAt: resolve(generatedAt),
  );
}

/// Sentinel that lets tests distinguish "use the default deterministic time"
/// from an explicit null timestamp.
final class _DefaultDateTimeMarker implements DateTime {
  const _DefaultDateTimeMarker();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
