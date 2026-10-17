/// Immutable, authoritative acceptance entries for a single Workshop task.
///
/// An Architect may abbreviate its narrative, but the original criteria
/// remain full-length and can be traced individually across each gate.
/// Task criteria come first so a bounded Engineer prompt sees the active
/// task's obligations before project-wide acceptance.
enum WorkshopAcceptanceScope { task, project }

final class WorkshopAcceptanceEntry {
  const WorkshopAcceptanceEntry({
    required this.id,
    required this.scope,
    required this.text,
  });

  final String id;
  final WorkshopAcceptanceScope scope;
  final String text;

  String get asConstraint =>
      '${scope == WorkshopAcceptanceScope.task ? 'Task' : 'Project'} '
      'acceptance [$id]: $text';
}

abstract final class WorkshopAcceptanceLedger {
  /// Stable ordinal IDs within a persisted task and its project plan.
  ///
  /// No criterion is silently dropped, shortened, merged or inferred.
  /// Duplicate owner-authored criteria stay present as distinct entries.
  static List<WorkshopAcceptanceEntry> entries({
    required List<String> taskCriteria,
    required List<String> projectCriteria,
  }) {
    final result = <WorkshopAcceptanceEntry>[];
    var taskIndex = 0;
    var projectIndex = 0;
    for (final raw in taskCriteria) {
      if (raw.trim().isEmpty) continue;
      taskIndex++;
      result.add(WorkshopAcceptanceEntry(
        id: 'TASK-${taskIndex.toString().padLeft(3, '0')}',
        scope: WorkshopAcceptanceScope.task,
        text: raw,
      ));
    }
    for (final raw in projectCriteria) {
      if (raw.trim().isEmpty) continue;
      projectIndex++;
      result.add(WorkshopAcceptanceEntry(
        id: 'PROJECT-${projectIndex.toString().padLeft(3, '0')}',
        scope: WorkshopAcceptanceScope.project,
        text: raw,
      ));
    }
    return List<WorkshopAcceptanceEntry>.unmodifiable(result);
  }
}
