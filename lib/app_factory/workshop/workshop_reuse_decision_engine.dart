import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';

/// Cost-aware policy for deciding whether verified local production knowledge
/// is strong enough to avoid a fresh AI generation.
final class WorkshopReusePolicy {
  const WorkshopReusePolicy({
    this.minimumMatchScore = 0.72,
    this.minimumValidationScore = 0.8,
    this.requireCapabilityCoverage = true,
  })  : assert(minimumMatchScore >= 0 && minimumMatchScore <= 1),
        assert(minimumValidationScore >= 0 && minimumValidationScore <= 1);

  final double minimumMatchScore;
  final double minimumValidationScore;
  final bool requireCapabilityCoverage;
}

/// Result of the reuse-first gate.
final class WorkshopReuseDecision {
  const WorkshopReuseDecision._({
    required this.shouldReuse,
    required this.reason,
    this.match,
  });

  final bool shouldReuse;
  final String reason;
  final WorkshopReuseMatch? match;

  WorkshopReusableAsset? get asset => match?.asset;

  factory WorkshopReuseDecision.reuse(WorkshopReuseMatch match) {
    return WorkshopReuseDecision._(
      shouldReuse: true,
      reason: 'verified-local-asset-match',
      match: match,
    );
  }

  factory WorkshopReuseDecision.generate(String reason) {
    return WorkshopReuseDecision._(
      shouldReuse: false,
      reason: reason,
    );
  }
}

/// Evaluates the local library before a task is sent to local/cloud generation.
///
/// It does not execute code, mutate projects, consume credits or call an LLM.
/// It only answers the question: "do we already have a sufficiently verified
/// solution worth reusing?".
final class WorkshopReuseDecisionEngine {
  const WorkshopReuseDecisionEngine({
    this.policy = const WorkshopReusePolicy(),
  });

  final WorkshopReusePolicy policy;

  WorkshopReuseDecision decide({
    required WorkshopReuseLibrary library,
    required String objective,
    List<String> requiredCapabilities = const <String>[],
    String? target,
  }) {
    final matches = library.search(
      objective: objective,
      requiredCapabilities: requiredCapabilities,
      target: target,
      limit: 5,
      verifiedOnly: false,
    );

    if (matches.isEmpty) {
      return WorkshopReuseDecision.generate('no-local-match');
    }

    for (final match in matches) {
      if (match.asset.validationScore < policy.minimumValidationScore) {
        continue;
      }

      if (match.score < policy.minimumMatchScore) {
        continue;
      }

      if (policy.requireCapabilityCoverage && requiredCapabilities.isNotEmpty) {
        final required = requiredCapabilities
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toSet();
        final available = match.asset.capabilities
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toSet();
        if (!available.containsAll(required)) {
          continue;
        }
      }

      return WorkshopReuseDecision.reuse(match);
    }

    return WorkshopReuseDecision.generate('local-match-below-threshold');
  }
}
