import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_reuse_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one Library pin selected for several capabilities is staged once', () {
    const candidate = WorkshopLibraryCandidate(
      assetId: 'voice.duplex_bundle',
      version: '1.0.0',
      capabilities: <String>['voice.stt', 'voice.tts'],
      contracts: <String>['voice.stt.v1', 'voice.tts.v1'],
      targets: <String>['android'],
      availability: WorkshopLibraryCandidateAvailability.active,
      validationScore: 0.95,
      resolutionScore: 0.9,
      integrationEffort: WorkshopLibraryIntegrationEffort.low,
      observedSuccessRate: 0.9,
      evidenceCount: 5,
    );

    WorkshopCapabilityNeed need(String capability, String contract) {
      return WorkshopCapabilityNeed(
        capabilityId: capability,
        preferredContractId: contract,
        priority: WorkshopProjectPriority.high,
        required: true,
        targets: const <String>['android'],
        evidence: const <WorkshopCapabilityEvidence>[],
      );
    }

    WorkshopCapabilityReuseDecision decision(
      String capability,
      String contract,
    ) {
      return WorkshopCapabilityReuseDecision(
        need: need(capability, contract),
        action: WorkshopCapabilityReuseAction.reuse,
        reason: 'certified-library-candidate-cheaper-than-fresh',
        evaluatedCandidates: 1,
        candidate: candidate,
      );
    }

    const package = WorkshopReusableModulePackage(
      assetId: 'voice.duplex_bundle',
      version: '1.0.0',
      capabilities: <String>['voice.stt', 'voice.tts'],
      contracts: <String>['voice.stt.v1', 'voice.tts.v1'],
      files: <WorkshopReusableModuleFile>[
        WorkshopReusableModuleFile(
          sourcePath: 'lib/duplex.dart',
          targetPath: 'lib/modules/voice/duplex.dart',
          content: 'class DuplexVoice {}\n',
        ),
      ],
    );

    final reusePlan = WorkshopProjectReusePlan(
      projectId: 'project-voice',
      generatedAt: DateTime.utc(2026, 9, 12),
      decisions: <WorkshopCapabilityReuseDecision>[
        decision('voice.tts', 'voice.tts.v1'),
        decision('voice.stt', 'voice.stt.v1'),
      ],
    );

    final assembly = const WorkshopModuleAssemblyPlanner().plan(
      reusePlan: reusePlan,
      packagesByPin: const <String, WorkshopReusableModulePackage>{
        'voice.duplex_bundle@1.0.0': package,
      },
      workspaceSnapshot: const <String, String>{},
    );

    expect(assembly.hasBlockingConflicts, isFalse);
    expect(assembly.pins, <String>['voice.duplex_bundle@1.0.0']);
    expect(assembly.changes, hasLength(1));
    expect(assembly.changes.single.path, 'lib/modules/voice/duplex.dart');
  });
}
