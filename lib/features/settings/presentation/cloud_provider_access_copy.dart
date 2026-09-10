import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';

/// User-facing copy for Point 1.5 Cloud access classifications.
///
/// Keep billing/access semantics centralized so Settings does not infer safety
/// from provider names or hard-coded provider-specific rules.
final class CloudProviderAccessCopy {
  const CloudProviderAccessCopy._();

  static String label(CloudProviderAccessClass accessClass) {
    return switch (accessClass) {
      CloudProviderAccessClass.recurringFreeTier => 'Recurring free tier',
      CloudProviderAccessClass.developmentPrototypeFreeAccess =>
        'Development / prototype free access',
      CloudProviderAccessClass.accountDependentFreeAccess =>
        'Account-dependent free access',
      CloudProviderAccessClass.promoCredit => 'Promotional credit',
      CloudProviderAccessClass.paid => 'Paid',
      CloudProviderAccessClass.unknown => 'Unknown cost status',
    };
  }

  static String description(CloudProviderAccessClass accessClass) {
    return switch (accessClass) {
      CloudProviderAccessClass.recurringFreeTier =>
        'Recurring provider free tier. Limits and quotas still apply.',
      CloudProviderAccessClass.developmentPrototypeFreeAccess =>
        'Free access intended for development or prototyping; production or '
            'higher-volume use may require a paid plan.',
      CloudProviderAccessClass.accountDependentFreeAccess =>
        'Free access depends on the provider account, region or current '
            'provider policy. Verify the account before relying on it.',
      CloudProviderAccessClass.promoCredit =>
        'Temporary promotional credit. Automatic use must not assume the '
            'credit will renew.',
      CloudProviderAccessClass.paid =>
        'Provider usage can incur charges. Automatic paid requests remain '
            'subject to the configured spending policy.',
      CloudProviderAccessClass.unknown =>
        'Cost status is not verified. Treat this provider as spend-sensitive '
            'until its billing status is known.',
    };
  }

  static bool isSpendSafeByClassification(
    CloudProviderDefinition definition,
  ) {
    return definition.costClass == CloudProviderCostClass.freeTier &&
        switch (definition.accessClass) {
          CloudProviderAccessClass.recurringFreeTier ||
          CloudProviderAccessClass.developmentPrototypeFreeAccess ||
          CloudProviderAccessClass.accountDependentFreeAccess => true,
          CloudProviderAccessClass.promoCredit ||
          CloudProviderAccessClass.paid ||
          CloudProviderAccessClass.unknown => false,
        };
  }
}
