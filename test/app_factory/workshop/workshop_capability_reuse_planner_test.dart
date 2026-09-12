import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final approvedAt = DateTime.utc(2026, 9, 12, 12);

  WorkshopCapabilityNeed need({
    required String capability,
    required String contract,
    bool required = true,
    List<String> targets = const <String>['android'],
  }) {
    return WorkshopCapabilityNeed(
      capabilityId: capability,
      preferredContractId: contract,
      priority: WorkshopProjectPriority.high,
      required: required,
      targets: targets,
      evidence: const <WorkshopCapabilityEvidence>[],
    );
  }

  WorkshopCapabilityShoppingList shoppingList(
    List<WorkshopCapabilityNeed> needs,
  ) {
    return WorkshopCapabilityShoppingList(
      projectId: 'project-1',
      generatedAt: approvedAt,
      approval: WorkshopProjectApprovalEvidence(
        projectId: 'project-1',
        approvalId: 'approval-1',
        approvedAt: approvedAt,
        approvedBy: 'owner',
      ),
      targets: const <String>['android'],
      needs: needs,
      unmappedInputs: const <String>[],
    );
  }

  WorkshopLibraryCandidate candidate({
    String assetId = 'voice.stt.fast',
    String version = '1.0.0',
    String capability = 'voice.stt',
    String contract = 'voice.stt.v1',
    List<String> targets = const <String>['android'],
    WorkshopLibraryCandidateAvailability availability =
        WorkshopLibraryCandidateAvailability.active,
    double validation = 0.95,
    double resolution = 0.90,
    WorkshopLibraryIntegrationEffort effort =
        WorkshopLibraryIntegrationEffort.low,
    double? successRate = 0.9,
    int evidenceCount = 5,
  }) {
    return WorkshopLibraryCandidate(
      assetId: assetId,
      version: version,
      capabilities: <String>[capability],
      contracts: <String>[contract],
      targets: targets,
      availability: availability,
      validationScore: validation,
      resolutionScore: resolution,
      integrationEffort: effort,
      observedSuccessRate: successRate,
      evidenceCount: evidenceCount,
    );
  }

  group('WorkshopCapabilityReusePlanner', () {
    test('reuses a certified active candidate when reuse is cheaper', () {
      final plan = const WorkshopCapabilityReusePlanner().plan(
        shoppingList: shoppingList(<WorkshopCapabilityNeed>[
          need(capability: 'voice.stt', contract: 'voice.stt.v1'),
        ]),
        candidates: <WorkshopLibraryCandidate>[candidate()],
      );

      expect(plan.decisions, hasLength(1));
      expect(plan.decisions.single.action, WorkshopCapabilityReuseAction.reuse);
      expect(plan.decisions.single.candidate?.pin, 'voice.stt.fast@1.0.0');
      expect(plan.decisions.single.cost!.savingsUnits, greaterThan(0));
      expect(plan.reusedCapabilityCount, 1);
      expect(plan.freshCapabilityCount, 0);
    });

    test('chooses lower total integration cost instead of highest raw score', () {
      final expensive = candidate(
        assetId: 'voice.stt.high-score',
        resolution: 0.99,
        validation: 0.99,
        effort: WorkshopLibraryIntegrationEffort.high,
      );
      final economical = candidate(
        assetId: 'voice.stt.economical',
        resolution: 0.82,
        validation: 0.90,
        effort: WorkshopLibraryIntegrationEffort.low,
      );

      final decision = const WorkshopCapabilityReusePlanner()
          .plan(
            shoppingList: shoppingList(<WorkshopCapabilityNeed>[
              need(capability: 'voice.stt', contract: 'voice.stt.v1'),
            ]),
            candidates: <WorkshopLibraryCandidate>[expensive, economical],
          )
          .decisions
          .single;

      expect(decision.action, WorkshopCapabilityReuseAction.reuse);
      expect(decision.candidate?.assetId, 'voice.stt.economical');
      expect(decision.evaluatedCandidates, 2);
    });

    test('required capability falls back to fresh work when none is eligible', () {
      final decision = const WorkshopCapabilityReusePlanner()
          .plan(
            shoppingList: shoppingList(<WorkshopCapabilityNeed>[
              need(capability: 'voice.stt', contract: 'voice.stt.v1'),
            ]),
            candidates: <WorkshopLibraryCandidate>[
              candidate(availability: WorkshopLibraryCandidateAvailability.revoked),
            ],
          )
          .decisions
          .single;

      expect(decision.action, WorkshopCapabilityReuseAction.generateFresh);
      expect(decision.reason, 'no-eligible-library-candidate');
    });

    test('advisory capability is deferred instead of forcing AI generation', () {
      final decision = const WorkshopCapabilityReusePlanner()
          .plan(
            shoppingList: shoppingList(<WorkshopCapabilityNeed>[
              need(
                capability: 'diagnostics.logging',
                contract: 'diagnostics.logging.v1',
                required: false,
              ),
            ]),
            candidates: const <WorkshopLibraryCandidate>[],
          )
          .decisions
          .single;

      expect(decision.action, WorkshopCapabilityReuseAction.deferAdvisory);
    });

    test('filters wrong contract, target, deprecated and low-quality candidates', () {
      final candidates = <WorkshopLibraryCandidate>[
        candidate(contract: 'voice.stt.v2'),
        candidate(targets: const <String>['linux']),
        candidate(availability: WorkshopLibraryCandidateAvailability.deprecated),
        candidate(validation: 0.70),
        candidate(resolution: 0.50),
      ];

      final decision = const WorkshopCapabilityReusePlanner()
          .plan(
            shoppingList: shoppingList(<WorkshopCapabilityNeed>[
              need(capability: 'voice.stt', contract: 'voice.stt.v1'),
            ]),
            candidates: candidates,
          )
          .decisions
          .single;

      expect(decision.action, WorkshopCapabilityReuseAction.generateFresh);
      expect(decision.evaluatedCandidates, 0);
    });

    test('fresh-work estimate can make reuse economically unattractive', () {
      final decision = const WorkshopCapabilityReusePlanner()
          .plan(
            shoppingList: shoppingList(<WorkshopCapabilityNeed>[
              need(capability: 'voice.stt', contract: 'voice.stt.v1'),
            ]),
            candidates: <WorkshopLibraryCandidate>[
              candidate(effort: WorkshopLibraryIntegrationEffort.medium),
            ],
            freshImplementationUnitsByCapability: const <String, double>{
              'voice.stt': 0.40,
            },
          )
          .decisions
          .single;

      expect(decision.action, WorkshopCapabilityReuseAction.generateFresh);
      expect(decision.reason, 'reuse-cost-not-better-than-fresh');
      expect(decision.candidate, isNotNull);
    });

    test('planning is deterministic regardless of candidate input order', () {
      final alpha = candidate(assetId: 'voice.stt.alpha');
      final beta = candidate(assetId: 'voice.stt.beta');
      final list = shoppingList(<WorkshopCapabilityNeed>[
        need(capability: 'voice.stt', contract: 'voice.stt.v1'),
      ]);
      const planner = WorkshopCapabilityReusePlanner();

      final first = planner.plan(
        shoppingList: list,
        candidates: <WorkshopLibraryCandidate>[beta, alpha],
      );
      final second = planner.plan(
        shoppingList: list,
        candidates: <WorkshopLibraryCandidate>[alpha, beta],
      );

      expect(first.toJson(), second.toJson());
      expect(first.decisions.single.candidate?.assetId, 'voice.stt.alpha');
    });
  });
}
