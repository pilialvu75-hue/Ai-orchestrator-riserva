/// H53: conservative, deterministic decision boundary for HYBRID handoffs.
/// This does not invoke a model or provider and cannot grant Cloud consent.
enum HybridExecutionTarget { local, cloud }

enum HybridHandoffPoint { beforeFirstToken, sentenceBoundary, stepBoundary, midSentence }

enum HybridDecisionReason {
  noNetwork,
  cloudNotAuthorized,
  cloudUnavailable,
  preferQuality,
  localCompletesSooner,
  switchCostOutweighsGain,
  preserveOngoingSentence,
  continueCurrent,
}

final class HybridCandidateEstimate {
  const HybridCandidateEstimate({
    required this.totalCompletionMs,
    required this.qualityScore,
    this.coldStartMs = 0,
    this.switchContextMs = 0,
    this.batteryPressure = 0,
  });

  /// Estimated remaining generation duration, excluding startup and handoff.
  final int totalCompletionMs;
  /// Task-specific, calibrated [0,1] score, NOT model size or marketing rank.
  final double qualityScore;
  final int coldStartMs;
  final int switchContextMs;
  /// Normalized [0,1] device-specific energy pressure.
  final double batteryPressure;

  int get totalMs => totalCompletionMs + coldStartMs + switchContextMs;

  bool get isValid =>
      totalCompletionMs >= 0 && coldStartMs >= 0 &&
      switchContextMs >= 0 && qualityScore.isFinite &&
      qualityScore >= 0 && qualityScore <= 1 &&
      batteryPressure.isFinite &&
      batteryPressure >= 0 && batteryPressure <= 1;
}

final class HybridSwitchDecision {
  const HybridSwitchDecision(this.target, this.reason);
  final HybridExecutionTarget target;
  final HybridDecisionReason reason;
}

/// Decides WHETHER to switch. Does not splice two independent token streams.
///
/// Caller must supply trustworthy real-world telemetry: if metrics are absent,
/// the current target remains in place (except an unavailable Cloud).
/// Cloud is never selected without authorization, connectivity and readiness.
/// Mid-sentence switches are prohibited, even if the candidate looks better.
abstract final class HybridSwitchDecisionPolicy {
  static const int minimumUsefulLatencyGainMs = 4000;
  static const double minimumQualityGain = 0.12;
  static const double severeBatteryPressure = 0.85;

  static HybridSwitchDecision choose({
    required HybridExecutionTarget current,
    required bool networkAvailable,
    required bool cloudAuthorized,
    required bool cloudReady,
    required bool localReady,
    required HybridHandoffPoint handoffPoint,
    HybridCandidateEstimate? local,
    HybridCandidateEstimate? cloud,
  }) {
    if (!networkAvailable || !cloudAuthorized || !cloudReady) {
      if (current == HybridExecutionTarget.cloud && localReady &&
          handoffPoint != HybridHandoffPoint.midSentence) {
        return HybridSwitchDecision(
          HybridExecutionTarget.local,
          !networkAvailable ? HybridDecisionReason.noNetwork
              : !cloudAuthorized ? HybridDecisionReason.cloudNotAuthorized
              : HybridDecisionReason.cloudUnavailable,
        );
      }
      return HybridSwitchDecision(current,
          !networkAvailable ? HybridDecisionReason.noNetwork
              : !cloudAuthorized ? HybridDecisionReason.cloudNotAuthorized
              : HybridDecisionReason.cloudUnavailable);
    }
    if (!localReady) {
      return const HybridSwitchDecision(
          HybridExecutionTarget.cloud, HybridDecisionReason.continueCurrent);
    }
    if (handoffPoint == HybridHandoffPoint.midSentence) {
      return HybridSwitchDecision(
          current, HybridDecisionReason.preserveOngoingSentence);
    }
    if (local == null || cloud == null || !local.isValid || !cloud.isValid) {
      return HybridSwitchDecision(
          current, HybridDecisionReason.continueCurrent);
    }
    // Quality dominates modest latency differences. An already running
    // sentence is never forcibly replaced to improve a speculative score.
    final qualityDelta = cloud.qualityScore - local.qualityScore;
    if (qualityDelta >= minimumQualityGain &&
        cloud.batteryPressure < severeBatteryPressure) {
      return const HybridSwitchDecision(
          HybridExecutionTarget.cloud, HybridDecisionReason.preferQuality);
    }
    if (qualityDelta <= -minimumQualityGain &&
        local.batteryPressure < severeBatteryPressure) {
      return const HybridSwitchDecision(
          HybridExecutionTarget.local, HybridDecisionReason.preferQuality);
    }
    final gainCloudMs = local.totalMs - cloud.totalMs;
    if (gainCloudMs >= minimumUsefulLatencyGainMs &&
        cloud.batteryPressure < severeBatteryPressure) {
      return const HybridSwitchDecision(
          HybridExecutionTarget.cloud, HybridDecisionReason.localCompletesSooner);
    }
    if (gainCloudMs <= -minimumUsefulLatencyGainMs &&
        local.batteryPressure < severeBatteryPressure) {
      return const HybridSwitchDecision(
          HybridExecutionTarget.local, HybridDecisionReason.localCompletesSooner);
    }
    return HybridSwitchDecision(
        current, HybridDecisionReason.switchCostOutweighsGain);
  }
}
