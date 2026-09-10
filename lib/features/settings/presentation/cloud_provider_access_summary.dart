import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';
import 'package:ai_orchestrator/features/settings/presentation/cloud_provider_access_copy.dart';

/// Provider-neutral summary consumed by Settings/diagnostics surfaces.
///
/// Keeping this small view model outside widgets prevents UI code from
/// re-implementing spend-safety rules or branching on provider ids.
final class CloudProviderAccessSummary {
  const CloudProviderAccessSummary({
    required this.providerId,
    required this.displayName,
    required this.accessLabel,
    required this.description,
    required this.spendSafeByClassification,
  });

  final String providerId;
  final String displayName;
  final String accessLabel;
  final String description;
  final bool spendSafeByClassification;

  static CloudProviderAccessSummary? forProvider(String providerId) {
    final definition = CloudProviderCatalog.definitionFor(providerId);
    if (definition == null) return null;

    return CloudProviderAccessSummary(
      providerId: definition.id,
      displayName: definition.displayName,
      accessLabel: CloudProviderAccessCopy.label(definition.accessClass),
      description: CloudProviderAccessCopy.description(definition.accessClass),
      spendSafeByClassification:
          CloudProviderAccessCopy.isSpendSafeByClassification(definition),
    );
  }
}
