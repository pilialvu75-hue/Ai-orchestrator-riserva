import 'package:ai_orchestrator/core/runtime/inference/hybrid_switch_decision_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const warmLocal = HybridCandidateEstimate(
    totalCompletionMs: 5000, qualityScore: 0.65);
const coldLocal = HybridCandidateEstimate(
    totalCompletionMs: 5000, coldStartMs: 12000, qualityScore: 0.65);
const capableCloud = HybridCandidateEstimate(
    totalCompletionMs: 8000, qualityScore: 0.91);

HybridSwitchDecision decide({
  HybridExecutionTarget current = HybridExecutionTarget.cloud,
  bool network = true,
  bool authorized = true,
  bool cloudReady = true,
  bool localReady = true,
  HybridHandoffPoint point = HybridHandoffPoint.stepBoundary,
  HybridCandidateEstimate? local = warmLocal,
  HybridCandidateEstimate? cloud = capableCloud,
}) => HybridSwitchDecisionPolicy.choose(
    current: current,
    networkAvailable: network,
    cloudAuthorized: authorized,
    cloudReady: cloudReady,
    localReady: localReady,
    handoffPoint: point,
    local: local,
    cloud: cloud);

void main() {
  test('HYBRID quality beats a 2-3 second latency lead', () {
    final choice = decide(current: HybridExecutionTarget.local);
    expect(choice.target, HybridExecutionTarget.cloud);
    expect(choice.reason, HybridDecisionReason.preferQuality);
  });

  test('do not start cold LOCAL for a marginal first token gain', () {
    final choice = decide(local: coldLocal);
    expect(choice.target, HybridExecutionTarget.cloud);
  });

  test('offline Cloud falls back only at a safe boundary', () {
    expect(decide(network: false).target, HybridExecutionTarget.local);
    expect(decide(
      network: false, point: HybridHandoffPoint.midSentence,
    ).target, HybridExecutionTarget.cloud);
  });

  test('no unauthorized Cloud even if its quality is superior', () {
    expect(decide(
      current: HybridExecutionTarget.local, authorized: false,
    ).target, HybridExecutionTarget.local);
  });

  test('Cloud after network recovery only at a safe boundary', () {
    expect(decide(
      current: HybridExecutionTarget.local,
      point: HybridHandoffPoint.midSentence,
    ).target, HybridExecutionTarget.local);
    expect(decide(
      current: HybridExecutionTarget.local,
      point: HybridHandoffPoint.sentenceBoundary,
    ).target, HybridExecutionTarget.cloud);
  });

  test('no switch when measured gain is less than threshold', () {
    const local = HybridCandidateEstimate(
      totalCompletionMs: 5500, qualityScore: 0.80);
    const cloud = HybridCandidateEstimate(
      totalCompletionMs: 8000, qualityScore: 0.82);
    expect(decide(local: local, cloud: cloud).target,
        HybridExecutionTarget.cloud);
    expect(decide(
      current: HybridExecutionTarget.local, local: local, cloud: cloud,
    ).target, HybridExecutionTarget.local);
  });

  test('an actual faster LOCAL finish outweighs a negligible quality gap', () {
    const local = HybridCandidateEstimate(
      totalCompletionMs: 2000, qualityScore: 0.81);
    const cloud = HybridCandidateEstimate(
      totalCompletionMs: 11000, qualityScore: 0.83);
    expect(decide(local: local, cloud: cloud).target,
        HybridExecutionTarget.local);
  });

  test('cold-start and handoff cost count against LOCAL', () {
    const local = HybridCandidateEstimate(
      totalCompletionMs: 2000, coldStartMs: 9000,
      switchContextMs: 3000, qualityScore: 0.80);
    const cloud = HybridCandidateEstimate(
      totalCompletionMs: 6000, qualityScore: 0.82);
    expect(decide(local: local, cloud: cloud).target,
        HybridExecutionTarget.cloud);
  });

  test('unmeasured candidate does not trigger speculative switching', () {
    expect(decide(
      current: HybridExecutionTarget.local, cloud: null,
    ).target, HybridExecutionTarget.local);
    expect(decide(
      current: HybridExecutionTarget.cloud, local: null,
    ).target, HybridExecutionTarget.cloud);
  });

  test('severe battery pressure vetoes optional switch', () {
    const local = HybridCandidateEstimate(
      totalCompletionMs: 12000, qualityScore: 0.79);
    const cloud = HybridCandidateEstimate(
      totalCompletionMs: 3000, qualityScore: 0.81, batteryPressure: 0.95);
    expect(decide(
      current: HybridExecutionTarget.local, local: local, cloud: cloud,
    ).target, HybridExecutionTarget.local);
  });

  test('invalid telemetry cannot select an unverified candidate', () {
    const invalid = HybridCandidateEstimate(
      totalCompletionMs: -1, qualityScore: 2.0);
    expect(decide(
      current: HybridExecutionTarget.local, cloud: invalid,
    ).target, HybridExecutionTarget.local);
  });
}
