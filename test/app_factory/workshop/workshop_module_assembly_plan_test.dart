import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopModuleAssemblyPlanner', () {
    const planner = WorkshopModuleAssemblyPlanner();

    test('stages exact reused package as addition-only proposal', () {
      final plan = planner.plan(
        reusePlan: _reusePlan(<WorkshopCapabilityReuseDecision>[
          _reuseDecision(
            need: _need('voice.stt', 'voice.stt.v1'),
            candidate: _candidate(
              assetId: 'voice.sherpa_stt',
              version: '2.4.1',
              capability: 'voice.stt',
              contract: 'voice.stt.v1',
            ),
          ),
        ]),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          'voice.sherpa_stt@2.4.1': _package(
            assetId: 'voice.sherpa_stt',
            version: '2.4.1',
            capability: 'voice.stt',
            contract: 'voice.stt.v1',
            files: const <WorkshopReusableModuleFile>[
              WorkshopReusableModuleFile(
                sourcePath: 'lib/sherpa_adapter.dart',
                targetPath: 'lib/modules/voice/sherpa_adapter.dart',
                content: 'class SherpaAdapter {}\n',
              ),
            ],
          ),
        },
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.hasBlockingConflicts, isFalse);
      expect(plan.pins, <String>['voice.sherpa_stt@2.4.1']);
      expect(plan.changes, hasLength(1));
      expect(plan.changes.single.type, WorkspaceChangeType.addition);
      expect(plan.changes.single.path, 'lib/modules/voice/sherpa_adapter.dart');

      final proposal = plan.buildChangeProposal(requestId: 'request-1');
      expect(proposal.changeCount, 1);
      expect(proposal.modifications, 0);
      expect(proposal.deletions, 0);
      expect(proposal.explanation, contains('voice.sherpa_stt@2.4.1'));
    });

    test('identical existing content is an idempotent no-op', () {
      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          'voice.sherpa_stt@2.4.1': _defaultPackage(),
        },
        workspaceSnapshot: const <String, String>{
          'lib/modules/voice/sherpa_adapter.dart': 'class SherpaAdapter {}\n',
        },
      );

      expect(plan.hasBlockingConflicts, isFalse);
      expect(plan.changes, isEmpty);
      expect(
        plan.identicalExistingPaths,
        <String>['lib/modules/voice/sherpa_adapter.dart'],
      );
    });

    test('never overwrites existing different content', () {
      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          'voice.sherpa_stt@2.4.1': _defaultPackage(),
        },
        workspaceSnapshot: const <String, String>{
          'lib/modules/voice/sherpa_adapter.dart': 'class ExistingAdapter {}\n',
        },
      );

      expect(plan.changes, isEmpty);
      expect(plan.hasBlockingConflicts, isTrue);
      expect(
        plan.conflicts.single.kind,
        WorkshopAssemblyConflictKind.existingDifferentContent,
      );
      expect(
        () => plan.buildChangeProposal(requestId: 'request-2'),
        throwsStateError,
      );
    });

    test('rejects unsafe paths and credential-like targets', () {
      final package = _package(
        assetId: 'voice.sherpa_stt',
        version: '2.4.1',
        capability: 'voice.stt',
        contract: 'voice.stt.v1',
        files: const <WorkshopReusableModuleFile>[
          WorkshopReusableModuleFile(
            sourcePath: 'a',
            targetPath: '../outside.dart',
            content: 'bad',
          ),
          WorkshopReusableModuleFile(
            sourcePath: 'b',
            targetPath: 'android/key.properties',
            content: 'secret',
          ),
          WorkshopReusableModuleFile(
            sourcePath: 'c',
            targetPath: 'build/generated.dart',
            content: 'generated',
          ),
        ],
      );

      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          package.pin: package,
        },
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.changes, isEmpty);
      expect(plan.conflicts, hasLength(3));
      expect(
        plan.conflicts.every(
          (item) => item.kind == WorkshopAssemblyConflictKind.unsafeTargetPath,
        ),
        isTrue,
      );
    });

    test('blocks two reused modules claiming the same target', () {
      final voiceNeed = _need('voice.stt', 'voice.stt.v1');
      final logNeed = _need('diagnostics.logging', 'diagnostics.logging.v1');
      final plan = planner.plan(
        reusePlan: _reusePlan(<WorkshopCapabilityReuseDecision>[
          _reuseDecision(
            need: voiceNeed,
            candidate: _candidate(
              assetId: 'voice.sherpa_stt',
              version: '2.4.1',
              capability: 'voice.stt',
              contract: 'voice.stt.v1',
            ),
          ),
          _reuseDecision(
            need: logNeed,
            candidate: _candidate(
              assetId: 'diag.logger',
              version: '1.0.0',
              capability: 'diagnostics.logging',
              contract: 'diagnostics.logging.v1',
            ),
          ),
        ]),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          'voice.sherpa_stt@2.4.1': _package(
            assetId: 'voice.sherpa_stt',
            version: '2.4.1',
            capability: 'voice.stt',
            contract: 'voice.stt.v1',
            files: const <WorkshopReusableModuleFile>[
              WorkshopReusableModuleFile(
                sourcePath: 'a.dart',
                targetPath: 'lib/shared/adapter.dart',
                content: 'voice',
              ),
            ],
          ),
          'diag.logger@1.0.0': _package(
            assetId: 'diag.logger',
            version: '1.0.0',
            capability: 'diagnostics.logging',
            contract: 'diagnostics.logging.v1',
            files: const <WorkshopReusableModuleFile>[
              WorkshopReusableModuleFile(
                sourcePath: 'b.dart',
                targetPath: 'lib/shared/adapter.dart',
                content: 'logging',
              ),
            ],
          ),
        },
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.hasBlockingConflicts, isTrue);
      expect(
        plan.conflicts.any(
          (item) => item.kind == WorkshopAssemblyConflictKind.duplicateTargetPath,
        ),
        isTrue,
      );
      expect(
        plan.changes.where((item) => item.path == 'lib/shared/adapter.dart'),
        hasLength(1),
      );
    });

    test('missing exact selected package blocks assembly', () {
      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: const <String, WorkshopReusableModulePackage>{},
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.hasBlockingConflicts, isTrue);
      expect(plan.changes, isEmpty);
      expect(
        plan.conflicts.single.kind,
        WorkshopAssemblyConflictKind.missingPackage,
      );
      expect(plan.conflicts.single.pin, 'voice.sherpa_stt@2.4.1');
    });

    test('keeps cross-cutting integration requirements explicit and deduplicated', () {
      const requirement = WorkshopAssemblyRequirement(
        kind: WorkshopAssemblyRequirementKind.permission,
        description: 'Declare microphone permission through the platform adapter.',
      );
      final package = _package(
        assetId: 'voice.sherpa_stt',
        version: '2.4.1',
        capability: 'voice.stt',
        contract: 'voice.stt.v1',
        files: const <WorkshopReusableModuleFile>[],
        requirements: const <WorkshopAssemblyRequirement>[
          requirement,
          requirement,
          WorkshopAssemblyRequirement(
            kind: WorkshopAssemblyRequirementKind.manualReview,
            description: 'Confirm locale policy.',
            required: false,
          ),
        ],
      );

      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: <String, WorkshopReusableModulePackage>{package.pin: package},
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.requirements, hasLength(2));
      expect(plan.requiresAdaptation, isTrue);
      final proposal = plan.buildChangeProposal(requestId: 'request-3');
      expect(proposal.validationNotes, hasLength(1));
      expect(proposal.validationNotes.single, contains('microphone permission'));
      expect(proposal.warnings, hasLength(1));
      expect(proposal.warnings.single, contains('locale policy'));
    });

    test('ignores fresh-generation decisions and remains deterministic', () {
      final reuse = _reuseDecision(
        need: _need('voice.stt', 'voice.stt.v1'),
        candidate: _candidate(
          assetId: 'voice.sherpa_stt',
          version: '2.4.1',
          capability: 'voice.stt',
          contract: 'voice.stt.v1',
        ),
      );
      final freshNeed = _need('network.http', 'network.http.v1');
      final fresh = WorkshopCapabilityReuseDecision(
        need: freshNeed,
        action: WorkshopCapabilityReuseAction.generateFresh,
        reason: 'no-eligible-library-candidate',
        evaluatedCandidates: 0,
      );
      final reusePlan = _reusePlan(<WorkshopCapabilityReuseDecision>[fresh, reuse]);
      final packages = <String, WorkshopReusableModulePackage>{
        'voice.sherpa_stt@2.4.1': _package(
          assetId: 'voice.sherpa_stt',
          version: '2.4.1',
          capability: 'voice.stt',
          contract: 'voice.stt.v1',
          files: const <WorkshopReusableModuleFile>[
            WorkshopReusableModuleFile(
              sourcePath: 'z.dart',
              targetPath: 'lib/z.dart',
              content: 'z',
            ),
            WorkshopReusableModuleFile(
              sourcePath: 'a.dart',
              targetPath: 'lib/a.dart',
              content: 'a',
            ),
          ],
        ),
      };

      final first = planner.plan(
        reusePlan: reusePlan,
        packagesByPin: packages,
        workspaceSnapshot: const <String, String>{},
      );
      final second = planner.plan(
        reusePlan: reusePlan,
        packagesByPin: packages,
        workspaceSnapshot: const <String, String>{},
      );

      expect(first.pins, <String>['voice.sherpa_stt@2.4.1']);
      expect(first.changes.map((item) => item.path), <String>['lib/a.dart', 'lib/z.dart']);
      expect(first.toJson(), second.toJson());
    });

    test('rejects package that does not provide selected Lego contract', () {
      final wrongPackage = _package(
        assetId: 'voice.sherpa_stt',
        version: '2.4.1',
        capability: 'voice.stt',
        contract: 'voice.stt.v2',
        files: const <WorkshopReusableModuleFile>[],
      );

      final plan = planner.plan(
        reusePlan: _singleReusePlan(),
        packagesByPin: <String, WorkshopReusableModulePackage>{
          wrongPackage.pin: wrongPackage,
        },
        workspaceSnapshot: const <String, String>{},
      );

      expect(plan.hasBlockingConflicts, isTrue);
      expect(
        plan.conflicts.single.kind,
        WorkshopAssemblyConflictKind.incompatiblePackage,
      );
    });
  });
}

WorkshopCapabilityNeed _need(String capability, String contract) {
  return WorkshopCapabilityNeed(
    capabilityId: capability,
    preferredContractId: contract,
    priority: WorkshopProjectPriority.high,
    required: true,
    targets: const <String>['android'],
    evidence: const <WorkshopCapabilityEvidence>[],
  );
}

WorkshopLibraryCandidate _candidate({
  required String assetId,
  required String version,
  required String capability,
  required String contract,
}) {
  return WorkshopLibraryCandidate(
    assetId: assetId,
    version: version,
    capabilities: <String>[capability],
    contracts: <String>[contract],
    targets: const <String>['android'],
    availability: WorkshopLibraryCandidateAvailability.active,
    validationScore: 0.95,
    resolutionScore: 0.9,
    integrationEffort: WorkshopLibraryIntegrationEffort.low,
    observedSuccessRate: 0.9,
    evidenceCount: 5,
  );
}

WorkshopCapabilityReuseDecision _reuseDecision({
  required WorkshopCapabilityNeed need,
  required WorkshopLibraryCandidate candidate,
}) {
  return WorkshopCapabilityReuseDecision(
    need: need,
    action: WorkshopCapabilityReuseAction.reuse,
    reason: 'certified-library-candidate-cheaper-than-fresh',
    evaluatedCandidates: 1,
    candidate: candidate,
  );
}

WorkshopProjectReusePlan _reusePlan(
  List<WorkshopCapabilityReuseDecision> decisions,
) {
  return WorkshopProjectReusePlan(
    projectId: 'project-1',
    generatedAt: DateTime.utc(2026, 9, 12, 12),
    decisions: decisions,
  );
}

WorkshopProjectReusePlan _singleReusePlan() {
  return _reusePlan(<WorkshopCapabilityReuseDecision>[
    _reuseDecision(
      need: _need('voice.stt', 'voice.stt.v1'),
      candidate: _candidate(
        assetId: 'voice.sherpa_stt',
        version: '2.4.1',
        capability: 'voice.stt',
        contract: 'voice.stt.v1',
      ),
    ),
  ]);
}

WorkshopReusableModulePackage _defaultPackage() {
  return _package(
    assetId: 'voice.sherpa_stt',
    version: '2.4.1',
    capability: 'voice.stt',
    contract: 'voice.stt.v1',
    files: const <WorkshopReusableModuleFile>[
      WorkshopReusableModuleFile(
        sourcePath: 'lib/sherpa_adapter.dart',
        targetPath: 'lib/modules/voice/sherpa_adapter.dart',
        content: 'class SherpaAdapter {}\n',
      ),
    ],
  );
}

WorkshopReusableModulePackage _package({
  required String assetId,
  required String version,
  required String capability,
  required String contract,
  required List<WorkshopReusableModuleFile> files,
  List<WorkshopAssemblyRequirement> requirements =
      const <WorkshopAssemblyRequirement>[],
}) {
  return WorkshopReusableModulePackage(
    assetId: assetId,
    version: version,
    capabilities: <String>[capability],
    contracts: <String>[contract],
    files: files,
    requirements: requirements,
    artifactDigest: 'sha256:test',
  );
}
