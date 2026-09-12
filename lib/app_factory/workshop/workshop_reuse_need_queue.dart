import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_need.dart';

/// Deterministic queue consumed by the autonomous Researcher.
///
/// The ordering implements the product rule defined for the Researcher:
/// complete one pass across the whole open list, then start again from the
/// highest-priority needs looking for better candidates. This is achieved by
/// sorting first by [WorkshopReuseNeed.cycleCount] ascending, then priority
/// descending, then oldest search time.
final class WorkshopReuseNeedQueue {
  WorkshopReuseNeedQueue({
    Iterable<WorkshopReuseNeed> initialNeeds = const <WorkshopReuseNeed>[],
  }) {
    for (final need in initialNeeds) {
      upsert(need);
    }
  }

  final Map<String, WorkshopReuseNeed> _needs = <String, WorkshopReuseNeed>{};

  int get length => _needs.length;

  List<WorkshopReuseNeed> get needs =>
      List<WorkshopReuseNeed>.unmodifiable(_needs.values);

  List<WorkshopReuseNeed> get openNeeds {
    final result = _needs.values.where((need) => need.isOpen).toList();
    result.sort(_compareForResearch);
    return List<WorkshopReuseNeed>.unmodifiable(result);
  }

  WorkshopReuseNeed? findById(String id) => _needs[id.trim()];

  void upsert(WorkshopReuseNeed need) {
    final id = need.id.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(need.id, 'need.id', 'Cannot be empty.');
    }
    _needs[id] = need;
  }

  bool remove(String id) => _needs.remove(id.trim()) != null;

  WorkshopReuseNeed? nextForResearch() {
    final pending = openNeeds;
    return pending.isEmpty ? null : pending.first;
  }

  WorkshopReuseNeed recordSearch({
    required String needId,
    DateTime? at,
    double? candidateScore,
  }) {
    final need = findById(needId);
    if (need == null) {
      throw StateError('Unknown reuse need: ${needId.trim()}');
    }
    final updated = need.markSearched(
      at: at,
      candidateScore: candidateScore,
    );
    _needs[updated.id] = updated;
    return updated;
  }

  WorkshopReuseNeed satisfy({
    required String needId,
    required String assetId,
    required double qualityScore,
  }) {
    final need = findById(needId);
    if (need == null) {
      throw StateError('Unknown reuse need: ${needId.trim()}');
    }
    final updated = need.satisfyWith(
      assetId: assetId,
      qualityScore: qualityScore,
    );
    _needs[updated.id] = updated;
    return updated;
  }

  WorkshopReuseNeed reopen(String needId) {
    final need = findById(needId);
    if (need == null) {
      throw StateError('Unknown reuse need: ${needId.trim()}');
    }
    final updated = need.reopenForImprovement();
    _needs[updated.id] = updated;
    return updated;
  }

  Map<String, dynamic> diagnostics() {
    final open = _needs.values.where((need) => need.isOpen).toList();
    final satisfied = _needs.values
        .where((need) => need.status == WorkshopReuseNeedStatus.satisfied)
        .length;
    final paused = _needs.values
        .where((need) => need.status == WorkshopReuseNeedStatus.paused)
        .length;
    final minimumCycle = open.isEmpty
        ? null
        : open
            .map((need) => need.cycleCount)
            .reduce((left, right) => left < right ? left : right);

    return <String, dynamic>{
      'needCount': length,
      'openCount': open.length,
      'satisfiedCount': satisfied,
      'pausedCount': paused,
      'currentCycle': minimumCycle,
      'nextNeedId': nextForResearch()?.id,
    };
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'needs': _needs.values.map((need) => need.toJson()).toList(),
      };

  factory WorkshopReuseNeedQueue.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['needs'] is! List) {
      return WorkshopReuseNeedQueue();
    }

    final needs = <WorkshopReuseNeed>[];
    for (final raw in json['needs'] as List) {
      if (raw is! Map) continue;
      try {
        needs.add(
          WorkshopReuseNeed.fromJson(Map<String, dynamic>.from(raw)),
        );
      } catch (_) {
        // One malformed need must not make the whole research queue unusable.
      }
    }
    return WorkshopReuseNeedQueue(initialNeeds: needs);
  }

  static int _compareForResearch(
    WorkshopReuseNeed left,
    WorkshopReuseNeed right,
  ) {
    final cycle = left.cycleCount.compareTo(right.cycleCount);
    if (cycle != 0) return cycle;

    final priority = right.priority.compareTo(left.priority);
    if (priority != 0) return priority;

    final leftSearch = left.lastSearchedAt;
    final rightSearch = right.lastSearchedAt;
    if (leftSearch == null && rightSearch != null) return -1;
    if (leftSearch != null && rightSearch == null) return 1;
    if (leftSearch != null && rightSearch != null) {
      final searched = leftSearch.compareTo(rightSearch);
      if (searched != 0) return searched;
    }

    final created = left.createdAt.compareTo(right.createdAt);
    if (created != 0) return created;
    return left.id.compareTo(right.id);
  }
}
