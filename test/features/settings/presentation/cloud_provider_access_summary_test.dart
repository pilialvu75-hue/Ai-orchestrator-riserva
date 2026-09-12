import 'package:ai_orchestrator/features/settings/presentation/cloud_provider_access_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds provider-neutral summaries for Point 1.5 providers', () {
    final groq = CloudProviderAccessSummary.forProvider('groq');
    final nim = CloudProviderAccessSummary.forProvider('nvidiaNim');
    final mistral = CloudProviderAccessSummary.forProvider('mistral');
    final openRouter = CloudProviderAccessSummary.forProvider('openRouter');

    expect(groq?.accessLabel, 'Recurring free tier');
    expect(nim?.accessLabel, 'Development / prototype free access');
    expect(mistral?.accessLabel, 'Account-dependent free access');
    expect(openRouter?.accessLabel, 'Account-dependent free access');

    expect(groq?.spendSafeByClassification, isTrue);
    expect(nim?.spendSafeByClassification, isFalse);
    expect(mistral?.spendSafeByClassification, isFalse);
    expect(openRouter?.spendSafeByClassification, isFalse);
  });

  test('unknown provider returns no summary', () {
    expect(CloudProviderAccessSummary.forProvider('not-a-provider'), isNull);
  });
}
