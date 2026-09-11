import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need.dart';

/// Source-agnostic candidate discovered by the autonomous Researcher.
///
/// This is intentionally not a verified reusable asset yet. Discovery and
/// verification are separate boundaries so internet search can never poison
/// the executable reuse catalog merely because a repository looked promising.
final class WorkshopResearchCandidate {
  WorkshopResearchCandidate({
    required this.id,
    required this.needId,
    required this.sourceUri,
    required this.title,
    required this.summary,
    this.sourceRevision,
    this.licenseId,
    this.capabilities = const <String>[],
    this.entryPaths = const <String>[],
    this.researchScore = 0,
    DateTime? discoveredAt,
  })  : assert(researchScore >= 0 && researchScore <= 1),
        discoveredAt = (discoveredAt ?? DateTime.now()).toUtc();

  final String id;
  final String needId;
  final String sourceUri;
  final String title;
  final String summary;
  final String? sourceRevision;
  final String? licenseId;
  final List<String> capabilities;
  final List<String> entryPaths;
  final double researchScore;
  final DateTime discoveredAt;

  bool get hasKnownLicense =>
      licenseId != null && licenseId!.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'needId': needId,
        'sourceUri': sourceUri,
        'title': title,
        'summary': summary,
        'sourceRevision': sourceRevision,
        'licenseId': licenseId,
        'capabilities': capabilities,
        'entryPaths': entryPaths,
        'researchScore': researchScore,
        'discoveredAt': discoveredAt.toIso8601String(),
      };
}

/// One bounded unit of work for an external/hosted Researcher.
///
/// A worker receives exactly one need, searches one or more configured sources,
/// and returns candidates plus evidence. The scheduler decides when to run the
/// next cycle; this contract contains no Android lifecycle assumptions.
final class WorkshopResearchJob {
  const WorkshopResearchJob({
    required this.need,
    required this.cycle,
  });

  final WorkshopReuseNeed need;
  final int cycle;
}

final class WorkshopResearchJobResult {
  const WorkshopResearchJobResult({
    required this.needId,
    required this.cycle,
    required this.candidates,
    this.notes = const <String>[],
  });

  final String needId;
  final int cycle;
  final List<WorkshopResearchCandidate> candidates;
  final List<String> notes;

  WorkshopResearchCandidate? get bestCandidate {
    if (candidates.isEmpty) return null;
    final sorted = List<WorkshopResearchCandidate>.from(candidates)
      ..sort((left, right) => right.researchScore.compareTo(left.researchScore));
    return sorted.first;
  }
}

/// Boundary implemented by the special autonomous Researcher project.
///
/// Concrete implementations may use GitHub, another website, a server worker,
/// or multiple search providers. AI-Orchestrator only depends on this contract
/// and on the serialized need/candidate models.
abstract interface class WorkshopResearcher {
  Future<WorkshopResearchJobResult> research(WorkshopResearchJob job);
}
