import 'package:ai_orchestrator/app_factory/workshop/workshop_researcher_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need_queue.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need_store.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WorkshopReuseNeedQueue', () {
    test('finishes one full pass before restarting from higher priority', () {
      final queue = WorkshopReuseNeedQueue(
        initialNeeds: <WorkshopReuseNeed>[
          WorkshopReuseNeed(
            id: 'low',
            title: 'Low priority',
            objective: 'Find a low-priority module',
            priority: 10,
            createdAt: DateTime.utc(2026, 9, 1),
          ),
          WorkshopReuseNeed(
            id: 'high',
            title: 'High priority',
            objective: 'Find a high-priority module',
            priority: 90,
            createdAt: DateTime.utc(2026, 9, 1),
          ),
        ],
      );

      expect(queue.nextForResearch()?.id, 'high');
      queue.recordSearch(
        needId: 'high',
        at: DateTime.utc(2026, 9, 11, 10),
        candidateScore: 0.6,
      );

      // The low-priority item is still on cycle 0, so it must be searched
      // before the high-priority item starts cycle 2.
      expect(queue.nextForResearch()?.id, 'low');
      queue.recordSearch(
        needId: 'low',
        at: DateTime.utc(2026, 9, 11, 11),
      );

      // Every open need completed one pass: restart from highest priority.
      expect(queue.nextForResearch()?.id, 'high');
      expect(queue.findById('high')?.cycleCount, 1);
      expect(queue.findById('low')?.cycleCount, 1);
    });

    test('satisfied need leaves active cycle and can later reopen for upgrades', () {
      final queue = WorkshopReuseNeedQueue(
        initialNeeds: <WorkshopReuseNeed>[
          WorkshopReuseNeed(
            id: 'auth',
            title: 'Authentication',
            objective: 'Reusable authentication module',
            minimumQualityScore: 0.85,
          ),
        ],
      );

      expect(
        () => queue.satisfy(
          needId: 'auth',
          assetId: 'weak-auth',
          qualityScore: 0.7,
        ),
        throwsStateError,
      );

      final satisfied = queue.satisfy(
        needId: 'auth',
        assetId: 'verified-auth',
        qualityScore: 0.92,
      );
      expect(satisfied.status, WorkshopReuseNeedStatus.satisfied);
      expect(queue.nextForResearch(), isNull);

      final reopened = queue.reopen('auth');
      expect(reopened.isOpen, isTrue);
      expect(reopened.incumbentAssetId, 'verified-auth');
      expect(reopened.bestCandidateScore, 0.92);
      expect(queue.nextForResearch()?.id, 'auth');
    });

    test('research result ranks strongest candidate without verifying it', () {
      final result = WorkshopResearchJobResult(
        needId: 'router',
        cycle: 3,
        candidates: <WorkshopResearchCandidate>[
          WorkshopResearchCandidate(
            id: 'a',
            needId: 'router',
            sourceUri: 'https://example.test/a',
            title: 'A',
            summary: 'Candidate A',
            researchScore: 0.61,
          ),
          WorkshopResearchCandidate(
            id: 'b',
            needId: 'router',
            sourceUri: 'https://example.test/b',
            title: 'B',
            summary: 'Candidate B',
            researchScore: 0.91,
            licenseId: 'MIT',
          ),
        ],
      );

      expect(result.bestCandidate?.id, 'b');
      expect(result.bestCandidate?.hasKnownLicense, isTrue);
    });
  });

  group('WorkshopReuseNeedStore', () {
    test('persists and restores the researcher cycle state', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );
      final store = WorkshopReuseNeedStore(preferences: preferences);
      final queue = WorkshopReuseNeedQueue(
        initialNeeds: <WorkshopReuseNeed>[
          WorkshopReuseNeed(
            id: 'voice-module',
            title: 'Voice module',
            objective: 'Find a reusable offline voice module',
            priority: 80,
            requiredCapabilities: const <String>['offline', 'streaming'],
            queryHints: const <String>['sherpa onnx', 'flutter'],
            target: 'android',
          ),
        ],
      );
      queue.recordSearch(
        needId: 'voice-module',
        at: DateTime.utc(2026, 9, 11, 12),
        candidateScore: 0.74,
      );

      await store.save(queue);
      final restored = await store.load();
      final need = restored.findById('voice-module');

      expect(need, isNotNull);
      expect(need!.cycleCount, 1);
      expect(need.bestCandidateScore, 0.74);
      expect(need.requiredCapabilities, contains('streaming'));
      expect(need.target, 'android');
      expect(restored.nextForResearch()?.id, 'voice-module');
    });

    test('corrupt persisted queue fails closed to an empty queue', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'workshop_reuse_need_queue_v1': '{not-json',
      });
      final preferences = PreferencesService(
        await SharedPreferences.getInstance(),
      );

      final restored =
          await WorkshopReuseNeedStore(preferences: preferences).load();

      expect(restored.length, 0);
      expect(restored.nextForResearch(), isNull);
    });
  });
}
