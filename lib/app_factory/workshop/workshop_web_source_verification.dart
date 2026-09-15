import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';

/// Kind of claim extracted from Web research.
///
/// Verification rules intentionally differ by claim kind. Community consensus
/// is useful for product sentiment, but it must never be treated as equivalent
/// to primary documentation for licensing, security or API compatibility.
enum WorkshopWebClaimKind {
  factual,
  technical,
  safetySecurity,
  legalLicensing,
  subjectiveSignal,
}

enum WorkshopWebSourceRole {
  primary,
  independentSecondary,
  community,
  unknown,
}

enum WorkshopWebSourceFreshness {
  current,
  stale,
  unknown,
}

enum WorkshopWebVerificationStatus {
  verified,
  supported,
  mixed,
  disputed,
  insufficientEvidence,
  referenceOnly,
}

/// One source's relationship to a claim.
///
/// [sourceFamily] is an independence hint, not a proof of editorial
/// independence. Callers should provide a stronger family identifier when
/// known (for example the publisher/organisation). When omitted, the exact
/// normalized host is used as a conservative fallback.
final class WorkshopWebSourceObservation {
  WorkshopWebSourceObservation({
    required this.source,
    required this.role,
    this.supportsClaim = false,
    this.contradictsClaim = false,
    this.freshness = WorkshopWebSourceFreshness.unknown,
    this.sourceFamily,
    this.explicitReuseTerms = false,
  }) : assert(
          !(supportsClaim && contradictsClaim),
          'A source observation cannot simultaneously support and contradict.',
        );

  final WorkshopWebResearchSource source;
  final WorkshopWebSourceRole role;
  final bool supportsClaim;
  final bool contradictsClaim;
  final WorkshopWebSourceFreshness freshness;
  final String? sourceFamily;

  /// True only when the source itself explicitly carries reuse/licensing terms
  /// applicable to the material being considered. This must never be inferred
  /// from third-party statements or a search-result majority.
  final bool explicitReuseTerms;

  String get independenceFamily {
    final explicit = sourceFamily?.trim().toLowerCase();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final parsed = Uri.tryParse(source.url.trim());
    final host = parsed?.host.trim().toLowerCase() ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }
}

/// Deterministic verification outcome.
///
/// [evidenceStrength] describes the strength/diversity of evidence available;
/// it is deliberately *not* a probability that the claim is true.
final class WorkshopWebClaimVerification {
  const WorkshopWebClaimVerification({
    required this.claim,
    required this.kind,
    required this.status,
    required this.evidenceStrength,
    required this.observations,
    required this.needsCorroboration,
    required this.reason,
  });

  final String claim;
  final WorkshopWebClaimKind kind;
  final WorkshopWebVerificationStatus status;
  final double evidenceStrength;
  final List<WorkshopWebSourceObservation> observations;
  final bool needsCorroboration;
  final String reason;

  bool get isVerified => status == WorkshopWebVerificationStatus.verified;

  /// Facts that can safely drive implementation without another verification
  /// round. Subjective signals intentionally never satisfy this getter.
  bool get canDriveFactualImplementation =>
      isVerified && kind != WorkshopWebClaimKind.subjectiveSignal;
}

/// Cross-source policy used by Cantiere after Web pages have been read.
///
/// This class does not decide what a page *means*. A claim extractor/adjudicator
/// supplies the observations. The policy then applies fail-closed rules for
/// source diversity, conflicts, freshness and licensing so an LLM cannot turn a
/// single attractive page into an unquestioned fact.
final class WorkshopWebVerificationPolicy {
  const WorkshopWebVerificationPolicy({
    this.minimumIndependentFamilies = 2,
  }) : assert(minimumIndependentFamilies >= 2);

  final int minimumIndependentFamilies;

  WorkshopWebClaimVerification evaluate({
    required String claim,
    required WorkshopWebClaimKind kind,
    required List<WorkshopWebSourceObservation> observations,
    bool requiresFreshness = false,
  }) {
    final normalizedClaim = claim.trim();
    final immutable = List<WorkshopWebSourceObservation>.unmodifiable(
      observations,
    );

    final relevant = observations.where((entry) {
      if (!requiresFreshness) return true;
      return entry.freshness != WorkshopWebSourceFreshness.stale;
    }).toList(growable: false);

    final support = relevant.where((entry) => entry.supportsClaim).toList();
    final contradict =
        relevant.where((entry) => entry.contradictsClaim).toList();

    if (kind == WorkshopWebClaimKind.subjectiveSignal) {
      return _evaluateSubjective(
        claim: normalizedClaim,
        kind: kind,
        observations: immutable,
        support: support,
        contradict: contradict,
      );
    }

    if (support.isNotEmpty && contradict.isNotEmpty) {
      return WorkshopWebClaimVerification(
        claim: normalizedClaim,
        kind: kind,
        status: WorkshopWebVerificationStatus.disputed,
        evidenceStrength: _strength(support, contradict),
        observations: immutable,
        needsCorroboration: true,
        reason: 'independent_evidence_conflicts',
      );
    }

    if (support.isEmpty) {
      return WorkshopWebClaimVerification(
        claim: normalizedClaim,
        kind: kind,
        status: WorkshopWebVerificationStatus.insufficientEvidence,
        evidenceStrength: 0,
        observations: immutable,
        needsCorroboration: true,
        reason: requiresFreshness && observations.isNotEmpty
            ? 'no_current_supporting_evidence'
            : 'no_supporting_evidence',
      );
    }

    if (kind == WorkshopWebClaimKind.legalLicensing) {
      final primaryTerms = support.any(
        (entry) =>
            entry.role == WorkshopWebSourceRole.primary &&
            entry.explicitReuseTerms &&
            entry.freshness != WorkshopWebSourceFreshness.stale,
      );
      if (!primaryTerms) {
        return WorkshopWebClaimVerification(
          claim: normalizedClaim,
          kind: kind,
          status: WorkshopWebVerificationStatus.referenceOnly,
          evidenceStrength: _strength(support, contradict).clamp(0, 0.49),
          observations: immutable,
          needsCorroboration: true,
          reason: 'reuse_terms_not_verified_at_primary_source',
        );
      }

      return WorkshopWebClaimVerification(
        claim: normalizedClaim,
        kind: kind,
        status: WorkshopWebVerificationStatus.verified,
        evidenceStrength: 1,
        observations: immutable,
        needsCorroboration: false,
        reason: 'explicit_primary_reuse_terms',
      );
    }

    final families = _independentFamilies(support);
    final hasPrimary = support.any(
      (entry) => entry.role == WorkshopWebSourceRole.primary,
    );

    if (kind == WorkshopWebClaimKind.safetySecurity) {
      final enoughFamilies = families.length >= minimumIndependentFamilies;
      if (hasPrimary && enoughFamilies) {
        return WorkshopWebClaimVerification(
          claim: normalizedClaim,
          kind: kind,
          status: WorkshopWebVerificationStatus.verified,
          evidenceStrength: 0.95,
          observations: immutable,
          needsCorroboration: false,
          reason: 'primary_plus_independent_security_corroboration',
        );
      }

      return WorkshopWebClaimVerification(
        claim: normalizedClaim,
        kind: kind,
        status: WorkshopWebVerificationStatus.supported,
        evidenceStrength: _strength(support, contradict).clamp(0, 0.79),
        observations: immutable,
        needsCorroboration: true,
        reason: 'security_claim_requires_primary_and_independent_support',
      );
    }

    if (families.length >= minimumIndependentFamilies) {
      return WorkshopWebClaimVerification(
        claim: normalizedClaim,
        kind: kind,
        status: WorkshopWebVerificationStatus.verified,
        evidenceStrength: hasPrimary ? 0.95 : 0.85,
        observations: immutable,
        needsCorroboration: false,
        reason: hasPrimary
            ? 'primary_and_independent_sources_agree'
            : 'multiple_source_families_agree',
      );
    }

    return WorkshopWebClaimVerification(
      claim: normalizedClaim,
      kind: kind,
      status: WorkshopWebVerificationStatus.supported,
      evidenceStrength: hasPrimary ? 0.72 : 0.55,
      observations: immutable,
      needsCorroboration: true,
      reason: hasPrimary
          ? 'single_primary_source_needs_corroboration'
          : 'single_source_family_needs_corroboration',
    );
  }

  WorkshopWebClaimVerification _evaluateSubjective({
    required String claim,
    required WorkshopWebClaimKind kind,
    required List<WorkshopWebSourceObservation> observations,
    required List<WorkshopWebSourceObservation> support,
    required List<WorkshopWebSourceObservation> contradict,
  }) {
    if (support.isEmpty && contradict.isEmpty) {
      return WorkshopWebClaimVerification(
        claim: claim,
        kind: kind,
        status: WorkshopWebVerificationStatus.insufficientEvidence,
        evidenceStrength: 0,
        observations: observations,
        needsCorroboration: true,
        reason: 'no_observed_user_signal',
      );
    }

    if (support.isNotEmpty && contradict.isNotEmpty) {
      return WorkshopWebClaimVerification(
        claim: claim,
        kind: kind,
        status: WorkshopWebVerificationStatus.mixed,
        evidenceStrength: _strength(support, contradict),
        observations: observations,
        needsCorroboration: false,
        reason: 'mixed_user_signal_preserved',
      );
    }

    final families = _independentFamilies(
      support.isNotEmpty ? support : contradict,
    );
    if (families.length >= minimumIndependentFamilies) {
      return WorkshopWebClaimVerification(
        claim: claim,
        kind: kind,
        status: WorkshopWebVerificationStatus.supported,
        evidenceStrength: 0.7,
        observations: observations,
        needsCorroboration: false,
        reason: 'multi_source_user_signal',
      );
    }

    return WorkshopWebClaimVerification(
      claim: claim,
      kind: kind,
      status: WorkshopWebVerificationStatus.referenceOnly,
      evidenceStrength: 0.35,
      observations: observations,
      needsCorroboration: true,
      reason: 'single_source_user_signal',
    );
  }

  Set<String> _independentFamilies(
    Iterable<WorkshopWebSourceObservation> observations,
  ) {
    return observations
        .map((entry) => entry.independenceFamily)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  double _strength(
    List<WorkshopWebSourceObservation> support,
    List<WorkshopWebSourceObservation> contradict,
  ) {
    final all = <WorkshopWebSourceObservation>[
      ...support,
      ...contradict,
    ];
    if (all.isEmpty) return 0;

    final families = _independentFamilies(all).length;
    final hasPrimary = all.any(
      (entry) => entry.role == WorkshopWebSourceRole.primary,
    );
    final base = (families / (minimumIndependentFamilies + 1)).clamp(0.0, 1.0);
    return (base + (hasPrimary ? 0.2 : 0)).clamp(0.0, 1.0);
  }
}
