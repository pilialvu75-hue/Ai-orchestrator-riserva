import 'package:flutter/material.dart';
import 'package:ai_orchestrator/features/settings/presentation/cloud_provider_access_summary.dart';

/// Provider-neutral Settings surface for Point 1.5 access classification.
class CloudProviderAccessCard extends StatelessWidget {
  const CloudProviderAccessCard({
    super.key,
    required this.summary,
  });

  final CloudProviderAccessSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('cloud_provider_access_summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            summary.accessLabel,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary.description,
            style: const TextStyle(color: Colors.white60, height: 1.35),
          ),
        ],
      ),
    );
  }
}
