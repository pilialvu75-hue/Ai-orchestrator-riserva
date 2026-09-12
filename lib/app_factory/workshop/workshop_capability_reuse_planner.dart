import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';

enum WorkshopLibraryCandidateAvailability {
  active,
  deprecated,
  revoked,
}

enum WorkshopLibraryIntegrationEffort {
  trivial,
  low,
  medium,
  high,
}

/// Transport-neutral view of one certified Library candidate.
///
/// The future Cantiere <-> Library bridge will map the Library offline snapshot
/// or remote resolver output into this model. Keeping the planner independent
/// from transport lets Cantiere policy be tested before the repositories are
/// physically connected.
final class WorkshopLibraryCandidate {
  const WorkshopLibraryCandidate({
    required this.assetId,
    required this.version,
    required this.capabilities,
    required this.contracts,
    required this.targets,
    required this.availability,
    required this.validationScore,
    required this.resolutionScore,
    required this.integrationEffort,
    this.observedSuccessRate,
    this.evidenceCount = 0,
  })  : assert(validationScore >= 0 && validationScore <= 1),
        assert(resolutionScore >= 0 && resolutionScore <= 1),
        assert(observedSuccessRate == null ||
            (observedSuccessRate >= 0 && observedSuccessRate <= 1)),
        assert(evidenceCount >= 0);

  final String assetId;
  final String version;
  final List<String> capabilities;
  final List<String> contracts;
  final List<String> targets;
  final WorkshopLibraryCandidateAvailability availability;
  final double validationScore;

  /// Transparent ranking score produced by the Module Library resolver.
  final double resolutionScore;
  final WorkshopLibraryIntegrationEffort integrationEffort;
  final double? observedSuccessRate;
  final int evidenceCount;

  String get pin => '$assetId@$version';
}

/// Normalized decision units used only to compare reuse with fresh work.
///
/// They are deliberately not currency or elapsed-time promises. Later Cantiere
/// accounting can supply measured fresh-work estimates through
/// [freshImplementationUnitsByCapability] without changing this policy surface.
final class WorkshopReuseEconomicPolicy {
  const WorkshopReuseEconomicPolicy({
    this.minimumValidationScore = 0.8,
    this.minimumResolutionScore = 0.65,
    this.defaultFreshImplementationUnits = 1.0,
    this.validationRiskWeight = 0.25,
    this.reliabilityRiskWeight = 0.20,
    this.evidenceUncertaintyWeight = 0.10,
    this.fullEvidenceCount = 5,
  })  : assert(minimumValidationScore >= 0 && minimumValidationScore <= 1),
        assert(minimumResolutionScore >= 0 && minimumResolutionScore <= 1),
        assert(defaultFreshImplementationUnits > 0),
        assert(validationRiskWeight >= 0),
        assert(reliabilityRiskWeight >= 0),
        assert(evidenceUncertaintyWeight >= 0),
        assert(fullEvidenceCount > 0);

  final double minimumValidationScore;
  final double minimumResolutionScore;
  final double defaultFreshImplementationUnits;
  final double validationRiskWeight;
  final double reliabilityRiskWeight;
  final double evidenceUncertaintyWeight;
  final int fullEvidenceCount;

  double effortUnits(WorkshopLibraryIntegrationEffort effort) => switch (effort) {
        WorkshopLibraryIntegrationEffort.trivial => 0.15,
        WorkshopLibraryIntegrationEffort.low => 0.30,
        WorkshopLibraryIntegrationEffort.medium => 0.60,
        WorkshopLibraryIntegrationEffort.high => 0.95,
      };
}

final class WorkshopReuseCostBreakdown {
  const WorkshopReuseCostBreakdown({
    required this.integrationUnits,
    required this.validationRiskUnits,
    required this.reliabilityRiskUnits,
    required this.evidenceUncertaintyUnits,
    required this.totalReuseUnits,
    required this.freshImplementationUnits,
  });

  final double integrationUnits;
  final double validationRiskUnits;
  final double reliabilityRiskUnits;
  final double evidenceUncertaintyUnits;
  final double totalReuseUnits;
  final double freshImplementationUnits;

  double get savingsUnits => freshImplementationUnits - totalReuseUnits;

  Map<String, Object?> toJson() => <String, Object?>{
        'integrationUnits': integrationUnits,
        'validationRiskUnits': validationRiskUnits,
        'reliabilityRiskUnits': reliabilityRiskUnits,
        'evidenceUncertaintyUnits': evidenceUncertaintyUnits,
        'totalReuseUnits': totalReuseUnits,
        'freshImplementationUnits': freshImplementationUnits,
        'savingsUnits': savingsUnits,
      };
}

enum WorkshopCapabilityReuseAction {
  reuse,
  generateFresh,
  deferAdvisory,
}

final class WorkshopCapabilityReuseDecision {
  const WorkshopCapabilityReuseDecision({
    required this.need,
    required this.action,
    required this.reason,
    required this.evaluatedCandidates,
    this.candidate,
    this.cost,
  });

  final WorkshopCapabilityNeed need;
  final WorkshopCapabilityReuseAction action;
  final String reason;
  final int evaluatedCandidates;
  final WorkshopLibraryCandidate? candidate;
  final WorkshopReuseCostBreakdown? cost;

  bool get avoidsFreshGeneration => action == WorkshopCapabilityReuseAction.reuse;

  Map<String, Object?> toJson() => <String, Object?>{
        'capabilityId': need.capabilityId,
        'contractId': need.preferredContractId,
        'required': need.required,
        'action': action.name,
        'reason': reason,
        'evaluatedCandidates': evaluatedCandidates,
        'candidate': candidate == null
            ? null
            : <String, Object?>{
                'assetId': candidate!.assetId,
                'version': candidate!.version,
                'pin': candidate!.pin,
              },
        'cost': cost?.toJson(),
      };
}

final class WorkshopProjectReusePlan {
  const WorkshopProjectReusePlan({
    required this.projectId,
    required this.generatedAt,
    required this.decisions,
  });

  final String projectId;
  final DateTime generatedAt;
  final List<WorkshopCapabilityReuseDecision> decisions;

  int get reusedCapabilityCount => decisions
      .where((item) => item.action == WorkshopCapabilityReuseAction.reuse)
      .length;

  int get freshCapabilityCount => decisions
      .where((item) => item.action == WorkshopCapabilityReuseAction.generateFresh)
      .length;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'projectId': projectId,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'reusedCapabilityCount': reusedCapabilityCount,
        'freshCapabilityCount': freshCapabilityCount,
        'decisions': decisions.map((item) => item.toJson()).toList(growable: false),
      };
}

/// Pure Cantiere-side reuse-first policy.
///
/// It consumes an approved project shopping list plus already-resolved Library
/// candidates. It never contacts the Library, mutates a workspace or calls AI.
/// A `generateFresh` action is therefore only a planning signal for the later
/// execution layer.
final class WorkshopCapabilityReusePlanner {
  const WorkshopCapabilityReusePlanner({
    this.policy = const WorkshopReuseEconomicPolicy(),
  });

  final WorkshopReuseEconomicPolicy policy;

  WorkshopProjectReusePlan plan({
    required WorkshopCapabilityShoppingList shoppingList,
    required List<WorkshopLibraryCandidate> candidates,
    Map<String, double> freshImplementationUnitsByCapability =
        const <String, double>{},
  }) {
    final decisions = shoppingList.needs
        .map(
          (need) => _planNeed(
            need,
            candidates,
            freshImplementationUnitsByCapability[need.capabilityId] ??
                policy.defaultFreshImplementationUnits,
          ),
        )
        .toList(growable: false);

    return WorkshopProjectReusePlan(
      projectId: shoppingList.projectId,
      generatedAt: shoppingList.generatedAt,
      decisions: List.unmodifiable(decisions),
    );
  }

  WorkshopCapabilityReuseDecision _planNeed(
    WorkshopCapabilityNeed need,
    List<WorkshopLibraryCandidate> candidates,
    double freshUnits,
  ) {
    if (freshUnits <= 0) {
      throw ArgumentError.value(
        freshUnits,
        'freshImplementationUnits',
        'must be greater than zero',
      );
    }

    final eligible = candidates.where((candidate) => _isEligible(need, candidate)).toList();
    if (eligible.isEmpty) {
      return WorkshopCapabilityReuseDecision(
        need: need,
        action: need.required
            ? WorkshopCapabilityReuseAction.generateFresh
            : WorkshopCapabilityReuseAction.deferAdvisory,
        reason: 'no-eligible-library-candidate',
        evaluatedCandidates: 0,
      );
    }

    final evaluated = eligible
        .map(
          (candidate) => _EvaluatedCandidate(
            candidate: candidate,
            cost: _estimateCost(candidate, freshUnits),
          ),
        )
        .toList();

    evaluated.sort(_compareEvaluated);
    final best = evaluated.first;

    if (best.cost.totalReuseUnits >= best.cost.freshImplementationUnits) {
      return WorkshopCapabilityReuseDecision(
        need: need,
        action: need.required
            ? WorkshopCapabilityReuseAction.generateFresh
            : WorkshopCapabilityReuseAction.deferAdvisory,
        reason: 'reuse-cost-not-better-than-fresh',
        evaluatedCandidates: evaluated.length,
        candidate: best.candidate,
        cost: best.cost,
      );
    }

    return WorkshopCapabilityReuseDecision(
      need: need,
      action: WorkshopCapabilityReuseAction.reuse,
      reason: 'certified-library-candidate-cheaper-than-fresh',
      evaluatedCandidates: evaluated.length,
      candidate: best.candidate,
      cost: best.cost,
    );
  }

  bool _isEligible(
    WorkshopCapabilityNeed need,
    WorkshopLibraryCandidate candidate,
  ) {
    if (candidate.availability != WorkshopLibraryCandidateAvailability.active) {
      return false;
    }
    if (candidate.validationScore < policy.minimumValidationScore ||
        candidate.resolutionScore < policy.minimumResolutionScore) {
      return false;
    }
    if (!candidate.capabilities.contains(need.capabilityId) ||
        !candidate.contracts.contains(need.preferredContractId)) {
      return false;
    }
    if (need.targets.isNotEmpty && !candidate.targets.toSet().containsAll(need.targets)) {
      return false;
    }
    return true;
  }

  WorkshopReuseCostBreakdown _estimateCost(
    WorkshopLibraryCandidate candidate,
    double freshUnits,
  ) {
    final integration = policy.effortUnits(candidate.integrationEffort);
    final validationRisk =
        (1 - candidate.validationScore) * policy.validationRiskWeight;
    final reliability = candidate.observedSuccessRate ?? 0.5;
    final reliabilityRisk = (1 - reliability) * policy.reliabilityRiskWeight;
    final evidenceConfidence =
        (candidate.evidenceCount / policy.fullEvidenceCount).clamp(0.0, 1.0);
    final uncertainty =
        (1 - evidenceConfidence) * policy.evidenceUncertaintyWeight;
    final total = integration + validationRisk + reliabilityRisk + uncertainty;

    return WorkshopReuseCostBreakdown(
      integrationUnits: integration,
      validationRiskUnits: validationRisk,
      reliabilityRiskUnits: reliabilityRisk,
      evidenceUncertaintyUnits: uncertainty,
      totalReuseUnits: total,
      freshImplementationUnits: freshUnits,
    );
  }

  static int _compareEvaluated(
    _EvaluatedCandidate left,
    _EvaluatedCandidate right,
  ) {
    var value = left.cost.totalReuseUnits.compareTo(right.cost.totalReuseUnits);
    if (value != 0) return value;
    value = right.candidate.resolutionScore.compareTo(left.candidate.resolutionScore);
    if (value != 0) return value;
    value = right.candidate.validationScore.compareTo(left.candidate.validationScore);
    if (value != 0) return value;
    value = right.candidate.evidenceCount.compareTo(left.candidate.evidenceCount);
    if (value != 0) return value;
    value = left.candidate.assetId.compareTo(right.candidate.assetId);
    if (value != 0) return value;
    return left.candidate.version.compareTo(right.candidate.version);
  }
}

final class _EvaluatedCandidate {
  const _EvaluatedCandidate({
    required this.candidate,
    required this.cost,
  });

  final WorkshopLibraryCandidate candidate;
  final WorkshopReuseCostBreakdown cost;
}
