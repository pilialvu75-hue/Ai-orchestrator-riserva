import 'package:flutter/foundation.dart';

import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_provider_catalog.dart';

enum CloudBackgroundRecoveryRetryRoute {
  /// A user-triggered retry must go back through the current AUTO router so the
  /// free-first/spend-safe policy is evaluated again from fresh runtime state.
  automaticRouter,

  /// The interrupted request pinned a provider that the catalog currently
  /// classifies as a recurring free tier. A user may explicitly retry that
  /// provider, but the request is still never replayed automatically.
  sameFreeProvider,

  /// Reusing the provider could create spend (or its cost is not proven free),
  /// therefore a retry is a new request and needs fresh explicit authorization.
  freshExplicitAuthorization,
}

@immutable
final class CloudBackgroundRecoveryDecision {
  const CloudBackgroundRecoveryDecision({
    required this.retryRoute,
    required this.automaticReplayAllowed,
    required this.requiresFreshSpendAuthorization,
    required this.providerId,
    required this.providerDisplayName,
    required this.notice,
  });

  final CloudBackgroundRecoveryRetryRoute retryRoute;
  final bool automaticReplayAllowed;
  final bool requiresFreshSpendAuthorization;
  final String? providerId;
  final String? providerDisplayName;
  final String notice;
}

/// Provider-aware recovery policy for Cloud requests that were left in-flight
/// by an app/process death.
///
/// This class deliberately does not perform a retry. No built-in provider is
/// currently treated as offering a verified idempotent replay contract for the
/// exact request path used by AI Orchestrator, so automatic replay stays
/// fail-closed. The policy only decides which *user-triggered* retry route is
/// spend-safe.
final class CloudBackgroundRecoveryPolicy {
  const CloudBackgroundRecoveryPolicy();

  CloudBackgroundRecoveryDecision decide(
    CloudBackgroundExecutionRecord record,
  ) {
    final providerHint = record.providerHint.trim().isEmpty
        ? 'auto'
        : record.providerHint.trim();
    final observedProvider = _nonEmpty(record.providerId);

    if (providerHint == 'auto') {
      final displayName = _displayName(observedProvider);
      final providerSuffix = displayName == null ? '' : ' on $displayName';
      return CloudBackgroundRecoveryDecision(
        retryRoute: CloudBackgroundRecoveryRetryRoute.automaticRouter,
        automaticReplayAllowed: false,
        requiresFreshSpendAuthorization: false,
        providerId: observedProvider,
        providerDisplayName: displayName,
        notice: 'A previous Cloud response$providerSuffix was interrupted by an '
            'app/process restart. It was not replayed automatically. Retry '
            'through AUTO so the current free-first/spend-safe policy is '
            'evaluated again.',
      );
    }

    final providerId = observedProvider ?? providerHint;
    final definition = CloudProviderCatalog.definitionFor(providerId);
    final displayName = definition?.displayName ?? providerId;
    final isProvenRecurringFree =
        definition?.accessClass == CloudProviderAccessClass.recurringFreeTier;

    if (isProvenRecurringFree) {
      return CloudBackgroundRecoveryDecision(
        retryRoute: CloudBackgroundRecoveryRetryRoute.sameFreeProvider,
        automaticReplayAllowed: false,
        requiresFreshSpendAuthorization: false,
        providerId: providerId,
        providerDisplayName: displayName,
        notice: 'A previous Cloud response on $displayName was interrupted by '
            'an app/process restart. It was not replayed automatically. You '
            'may retry it explicitly; the provider is currently classified as '
            'a recurring free-tier route.',
      );
    }

    return CloudBackgroundRecoveryDecision(
      retryRoute:
          CloudBackgroundRecoveryRetryRoute.freshExplicitAuthorization,
      automaticReplayAllowed: false,
      requiresFreshSpendAuthorization: true,
      providerId: providerId,
      providerDisplayName: displayName,
      notice: 'A previous Cloud response on $displayName was interrupted by an '
          'app/process restart. It was not replayed automatically. Retrying '
          'this provider is a new request and requires a fresh explicit '
          'authorization because its cost is paid or not proven recurring-free.',
    );
  }

  String noticeFor(List<CloudBackgroundExecutionRecord> records) {
    if (records.isEmpty) return '';
    if (records.length == 1) return decide(records.single).notice;

    final decisions = records.map(decide).toList(growable: false);
    final autoCount = decisions
        .where(
          (item) =>
              item.retryRoute ==
              CloudBackgroundRecoveryRetryRoute.automaticRouter,
        )
        .length;
    final freshAuthorizationCount = decisions
        .where((item) => item.requiresFreshSpendAuthorization)
        .length;
    final freePinnedCount = decisions.length - autoCount - freshAuthorizationCount;

    final guidance = <String>[];
    if (autoCount > 0) {
      guidance.add('$autoCount must retry through AUTO');
    }
    if (freePinnedCount > 0) {
      guidance.add('$freePinnedCount may retry the same recurring-free provider');
    }
    if (freshAuthorizationCount > 0) {
      guidance.add(
        '$freshAuthorizationCount require fresh explicit provider authorization',
      );
    }

    return '${records.length} previous Cloud responses were interrupted by an '
        'app/process restart. None were replayed automatically. '
        '${guidance.join('; ')}.';
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _displayName(String? providerId) {
    if (providerId == null) return null;
    return CloudProviderCatalog.definitionFor(providerId)?.displayName ??
        providerId;
  }
}
