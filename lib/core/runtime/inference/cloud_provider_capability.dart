class CloudProviderCapability {
  const CloudProviderCapability({
    required this.id,
    required this.supportsFreeTierFallback,
    required this.supportsCodingAcceleration,
    required this.supportsReasoningAcceleration,
  });

  final String id;
  final bool supportsFreeTierFallback;
  final bool supportsCodingAcceleration;
  final bool supportsReasoningAcceleration;
}

class CloudProviderHealthSnapshot {
  const CloudProviderHealthSnapshot({
    required this.providerId,
    required this.totalRequests,
    required this.failedRequests,
    required this.quotaExhausted,
    this.rateLimitedUntilEpochMs,
    this.lastError,
  });

  final String providerId;
  final int totalRequests;
  final int failedRequests;
  final bool quotaExhausted;
  final int? rateLimitedUntilEpochMs;
  final String? lastError;
}
