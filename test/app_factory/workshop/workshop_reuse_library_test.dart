import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_decision_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopReuseLibrary', () {
    test('ranks a verified matching asset before unrelated assets', () {
      final library = WorkshopReuseLibrary(
        initialAssets: <WorkshopReusableAsset>[
          _asset(
            id: 'invoice-app',
            name: 'Invoice app foundation',
            description: 'Reusable invoicing project with customers and invoices',
            tags: const <String>['billing', 'invoice'],
            capabilities: const <String>['customers', 'invoices'],
            target: 'android',
          ),
          _asset(
            id: 'weather-app',
            name: 'Weather dashboard',
            description: 'Weather forecast dashboard',
            tags: const <String>['weather'],
            capabilities: const <String>['forecast'],
            target: 'android',
          ),
        ],
      );

      final matches = library.search(
        objective: 'create invoice billing app for customers',
        requiredCapabilities: const <String>['customers', 'invoices'],
        target: 'android',
      );

      expect(matches, isNotEmpty);
      expect(matches.first.asset.id, 'invoice-app');
      expect(matches.first.reasons, contains('objective-match'));
      expect(matches.first.reasons, contains('capability-match'));
      expect(matches.first.reasons, contains('target-match'));
    });

    test('does not return unverified assets when verifiedOnly is enabled', () {
      final library = WorkshopReuseLibrary(
        initialAssets: <WorkshopReusableAsset>[
          _asset(
            id: 'draft',
            name: 'Draft login',
            description: 'Login component',
            tags: const <String>['login'],
            capabilities: const <String>['authentication'],
            validationScore: 0.4,
          ),
        ],
      );

      expect(
        library.search(objective: 'login authentication'),
        isEmpty,
      );
    });

    test('round-trips descriptors and preserves reuse evidence', () {
      final library = WorkshopReuseLibrary(
        initialAssets: <WorkshopReusableAsset>[
          _asset(
            id: 'login',
            name: 'Verified login',
            description: 'Reusable authentication module',
            tags: const <String>['auth'],
            capabilities: const <String>['authentication'],
          ),
        ],
      );

      library.markUsed('login', at: DateTime.utc(2026, 9, 11));
      final restored = WorkshopReuseLibrary.fromJson(library.toJson());
      final asset = restored.findById('login');

      expect(asset, isNotNull);
      expect(asset!.reuseCount, 1);
      expect(asset.lastUsedAt, DateTime.utc(2026, 9, 11));
    });
  });

  group('WorkshopReuseDecisionEngine', () {
    test('reuses a strong verified local match', () {
      final library = WorkshopReuseLibrary(
        initialAssets: <WorkshopReusableAsset>[
          _asset(
            id: 'invoice-app',
            name: 'Invoice billing app',
            description: 'Invoice billing customers project',
            tags: const <String>['invoice', 'billing', 'customers'],
            capabilities: const <String>['customers', 'invoices'],
            target: 'android',
            validationScore: 0.98,
            reuseCount: 3,
          ),
        ],
      );

      final decision = const WorkshopReuseDecisionEngine().decide(
        library: library,
        objective: 'invoice billing app for customers',
        requiredCapabilities: const <String>['customers', 'invoices'],
        target: 'android',
      );

      expect(decision.shouldReuse, isTrue);
      expect(decision.asset?.id, 'invoice-app');
      expect(decision.reason, 'verified-local-asset-match');
    });

    test('falls through to generation when capability coverage is incomplete', () {
      final library = WorkshopReuseLibrary(
        initialAssets: <WorkshopReusableAsset>[
          _asset(
            id: 'partial',
            name: 'Invoice shell',
            description: 'Invoice billing app shell',
            tags: const <String>['invoice', 'billing'],
            capabilities: const <String>['customers'],
            validationScore: 1,
          ),
        ],
      );

      final decision = const WorkshopReuseDecisionEngine().decide(
        library: library,
        objective: 'invoice billing app',
        requiredCapabilities: const <String>['customers', 'invoices'],
      );

      expect(decision.shouldReuse, isFalse);
      expect(decision.reason, 'local-match-below-threshold');
    });
  });
}

WorkshopReusableAsset _asset({
  required String id,
  required String name,
  required String description,
  List<String> tags = const <String>[],
  List<String> capabilities = const <String>[],
  String? target,
  double validationScore = 1,
  int reuseCount = 0,
}) {
  return WorkshopReusableAsset(
    id: id,
    name: name,
    kind: WorkshopReusableAssetKind.module,
    origin: WorkshopReusableAssetOrigin.completedProject,
    description: description,
    tags: tags,
    capabilities: capabilities,
    target: target,
    validationScore: validationScore,
    reuseCount: reuseCount,
    artifactPath: 'artifacts/$id',
  );
}
