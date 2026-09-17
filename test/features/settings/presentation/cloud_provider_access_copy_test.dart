import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/features/settings/presentation/cloud_provider_access_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudProviderAccessCopy', () {
    test('exposes every Point 1.5 access class distinctly', () {
      expect(
        CloudProviderAccessCopy.label(
          CloudProviderAccessClass.recurringFreeTier,
        ),
        'Recurring free tier',
      );
      expect(
        CloudProviderAccessCopy.label(
          CloudProviderAccessClass.developmentPrototypeFreeAccess,
        ),
        'Development / prototype free access',
      );
      expect(
        CloudProviderAccessCopy.label(
          CloudProviderAccessClass.accountDependentFreeAccess,
        ),
        'Account-dependent free access',
      );
      expect(
        CloudProviderAccessCopy.label(CloudProviderAccessClass.promoCredit),
        'Promotional credit',
      );
      expect(
        CloudProviderAccessCopy.label(CloudProviderAccessClass.paid),
        'Paid',
      );
      expect(
        CloudProviderAccessCopy.label(CloudProviderAccessClass.unknown),
        'Unknown cost status',
      );
    });

    test('only verified recurring free-tier routes are spend-safe', () {
      final openRouter = CloudProviderCatalog.definitionFor('openRouter');
      expect(openRouter, isNotNull);
      expect(
        CloudProviderAccessCopy.isSpendSafeByClassification(openRouter!),
        isTrue,
      );

      for (final providerId in <String>[
        'groq',
        'nvidiaNim',
        'mistral',
      ]) {
        final definition = CloudProviderCatalog.definitionFor(providerId);
        expect(definition, isNotNull, reason: providerId);
        expect(
          CloudProviderAccessCopy.isSpendSafeByClassification(definition!),
          isFalse,
          reason: providerId,
        );
      }

      const accountDependentDeclaredFree = CloudProviderDefinition(
        id: 'custom_free',
        displayName: 'Custom free',
        defaultModel: 'model',
        capabilities: <CloudProviderCapability>{CloudProviderCapability.general},
        costClass: CloudProviderCostClass.freeTier,
        accessClass: CloudProviderAccessClass.accountDependentFreeAccess,
      );
      expect(
        CloudProviderAccessCopy.isSpendSafeByClassification(
          accountDependentDeclaredFree,
        ),
        isFalse,
      );
    });

    test('paid and unknown providers are never classified spend-safe', () {
      for (final providerId in <String>[
        'openAi',
        'claude',
        'grok',
        'copilot',
      ]) {
        final definition = CloudProviderCatalog.definitionFor(providerId);
        expect(definition, isNotNull, reason: providerId);
        expect(
          CloudProviderAccessCopy.isSpendSafeByClassification(definition!),
          isFalse,
          reason: providerId,
        );
      }
    });
  });
}
