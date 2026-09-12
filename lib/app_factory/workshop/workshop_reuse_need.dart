/// Priority/status contract for a capability the reusable Workshop library still
/// needs or wants to improve.
///
/// This model is intentionally provider-neutral: an always-on Researcher may
/// live outside the Android app (for example on GitHub or another hosted
/// service) and consume the same serialized contract without owning Workshop
/// inference/runtime state.
enum WorkshopReuseNeedStatus {
  open,
  satisfied,
  paused,
}

final class WorkshopReuseNeed {
  WorkshopReuseNeed({
    required this.id,
    required this.title,
    required this.objective,
    this.requiredCapabilities = const <String>[],
    this.queryHints = const <String>[],
    this.target,
    this.priority = 50,
    this.minimumQualityScore = 0.8,
    this.status = WorkshopReuseNeedStatus.open,
    this.incumbentAssetId,
    this.bestCandidateScore,
    this.cycleCount = 0,
    DateTime? createdAt,
    DateTime? lastSearchedAt,
  })  : assert(priority >= 0 && priority <= 100),
        assert(minimumQualityScore >= 0 && minimumQualityScore <= 1),
        assert(bestCandidateScore == null ||
            (bestCandidateScore >= 0 && bestCandidateScore <= 1)),
        assert(cycleCount >= 0),
        createdAt = (createdAt ?? DateTime.now()).toUtc(),
        lastSearchedAt = lastSearchedAt?.toUtc();

  final String id;
  final String title;
  final String objective;
  final List<String> requiredCapabilities;
  final List<String> queryHints;
  final String? target;
  final int priority;
  final double minimumQualityScore;
  final WorkshopReuseNeedStatus status;
  final String? incumbentAssetId;
  final double? bestCandidateScore;
  final int cycleCount;
  final DateTime createdAt;
  final DateTime? lastSearchedAt;

  bool get isOpen => status == WorkshopReuseNeedStatus.open;

  WorkshopReuseNeed markSearched({
    DateTime? at,
    double? candidateScore,
  }) {
    final boundedCandidate = candidateScore?.clamp(0.0, 1.0).toDouble();
    final best = bestCandidateScore == null
        ? boundedCandidate
        : boundedCandidate == null
            ? bestCandidateScore
            : (boundedCandidate > bestCandidateScore!
                ? boundedCandidate
                : bestCandidateScore);

    return copyWith(
      cycleCount: cycleCount + 1,
      lastSearchedAt: (at ?? DateTime.now()).toUtc(),
      bestCandidateScore: best,
    );
  }

  WorkshopReuseNeed satisfyWith({
    required String assetId,
    required double qualityScore,
  }) {
    final normalizedAssetId = assetId.trim();
    if (normalizedAssetId.isEmpty) {
      throw ArgumentError.value(assetId, 'assetId', 'Cannot be empty.');
    }
    final bounded = qualityScore.clamp(0.0, 1.0).toDouble();
    if (bounded < minimumQualityScore) {
      throw StateError(
        'Candidate quality $bounded is below required '
        '$minimumQualityScore for reuse need "$id".',
      );
    }

    return copyWith(
      status: WorkshopReuseNeedStatus.satisfied,
      incumbentAssetId: normalizedAssetId,
      bestCandidateScore: bounded,
    );
  }

  WorkshopReuseNeed reopenForImprovement() => copyWith(
        status: WorkshopReuseNeedStatus.open,
      );

  WorkshopReuseNeed copyWith({
    String? id,
    String? title,
    String? objective,
    List<String>? requiredCapabilities,
    List<String>? queryHints,
    String? target,
    int? priority,
    double? minimumQualityScore,
    WorkshopReuseNeedStatus? status,
    String? incumbentAssetId,
    double? bestCandidateScore,
    int? cycleCount,
    DateTime? createdAt,
    DateTime? lastSearchedAt,
  }) {
    return WorkshopReuseNeed(
      id: id ?? this.id,
      title: title ?? this.title,
      objective: objective ?? this.objective,
      requiredCapabilities:
          requiredCapabilities ?? this.requiredCapabilities,
      queryHints: queryHints ?? this.queryHints,
      target: target ?? this.target,
      priority: priority ?? this.priority,
      minimumQualityScore: minimumQualityScore ?? this.minimumQualityScore,
      status: status ?? this.status,
      incumbentAssetId: incumbentAssetId ?? this.incumbentAssetId,
      bestCandidateScore: bestCandidateScore ?? this.bestCandidateScore,
      cycleCount: cycleCount ?? this.cycleCount,
      createdAt: createdAt ?? this.createdAt,
      lastSearchedAt: lastSearchedAt ?? this.lastSearchedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'objective': objective,
        'requiredCapabilities': requiredCapabilities,
        'queryHints': queryHints,
        'target': target,
        'priority': priority,
        'minimumQualityScore': minimumQualityScore,
        'status': status.name,
        'incumbentAssetId': incumbentAssetId,
        'bestCandidateScore': bestCandidateScore,
        'cycleCount': cycleCount,
        'createdAt': createdAt.toIso8601String(),
        'lastSearchedAt': lastSearchedAt?.toIso8601String(),
      };

  factory WorkshopReuseNeed.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final title = json['title']?.toString().trim() ?? '';
    final objective = json['objective']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty || objective.isEmpty) {
      throw const FormatException(
        'Reuse need requires non-empty id, title and objective.',
      );
    }

    return WorkshopReuseNeed(
      id: id,
      title: title,
      objective: objective,
      requiredCapabilities: _stringList(json['requiredCapabilities']),
      queryHints: _stringList(json['queryHints']),
      target: _optionalString(json['target']),
      priority: (json['priority'] is num
              ? (json['priority'] as num).toInt()
              : 50)
          .clamp(0, 100)
          .toInt(),
      minimumQualityScore: (json['minimumQualityScore'] is num
              ? (json['minimumQualityScore'] as num).toDouble()
              : 0.8)
          .clamp(0.0, 1.0)
          .toDouble(),
      status: WorkshopReuseNeedStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => WorkshopReuseNeedStatus.open,
      ),
      incumbentAssetId: _optionalString(json['incumbentAssetId']),
      bestCandidateScore: json['bestCandidateScore'] is num
          ? (json['bestCandidateScore'] as num)
              .toDouble()
              .clamp(0.0, 1.0)
              .toDouble()
          : null,
      cycleCount: json['cycleCount'] is num
          ? (json['cycleCount'] as num)
              .toInt()
              .clamp(0, 1 << 30)
              .toInt()
          : 0,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '')
              ?.toUtc() ??
          DateTime.now().toUtc(),
      lastSearchedAt:
          DateTime.tryParse(json['lastSearchedAt']?.toString() ?? '')?.toUtc(),
    );
  }

  static String? _optionalString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    final seen = <String>{};
    final result = <String>[];
    for (final item in value) {
      final normalized = item.toString().trim();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized.toLowerCase())) result.add(normalized);
    }
    return List<String>.unmodifiable(result);
  }
}
