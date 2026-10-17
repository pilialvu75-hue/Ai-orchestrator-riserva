/// Shared bounded projection of the Architect plan consumed by Engineer,
/// Reviewer and Validation. All three receive exactly the same projection.
///
/// Preserve the start/end and explicit acceptance/requirement lines from the
/// omitted middle where possible. Owner requirements remain authoritative in
/// the WorkshopRequest; this is only an advisory Architect-plan projection.
abstract final class WorkshopTaskPlanProjection {
  static const int maxChars = 900;
  static const String _omissionMarker = '\n...[bounded middle omitted]...\n';
  static const String _priorityMarker = '\n...[middle requirements]...\n';
  static const int _maxMiddlePriorityChars = 320;

  static final RegExp _priorityLine = RegExp(
    r'^(?:acceptance|requirement|constraints?|mandatory|must|criteria|'
    r'criteri|requisit[io]|vincol[io])\b\s*[:\-]',
    caseSensitive: false,
  );

  static String project(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.length <= maxChars) return normalized;

    final remaining = maxChars - _omissionMarker.length;
    final normalHead = (remaining * 3) ~/ 5;
    final normalTail = remaining - normalHead;

    // Look at *only* the middle that would otherwise be discarded. This
    // avoids repeating the criteria already visible in the head/tail.
    final middle = normalized.substring(
      normalHead,
      normalized.length - normalTail,
    );
    final priority = <String>[];
    var priorityChars = 0;
    for (final rawLine in middle.split('\n')) {
      final line = rawLine.trim();
      if (!_priorityLine.hasMatch(line)) continue;
      if (line.isEmpty || priority.contains(line)) continue;
      final cost = line.length + (priority.isEmpty ? 0 : 1);
      if (priorityChars + cost > _maxMiddlePriorityChars) continue;
      priority.add(line);
      priorityChars += cost;
    }
    if (priority.isEmpty) {
      return normalized.substring(0, normalHead) +
          _omissionMarker +
          normalized.substring(normalized.length - normalTail);
    }

    // Make room for the complete matched lines, not partial/truncated
    // acceptance criteria. If too many lines exist, the owner contract in the
    // request remains authoritative and this projection never claims completeness.
    final middlePriority = priority.join('\n');
    final budget = maxChars -
        _omissionMarker.length -
        _priorityMarker.length -
        middlePriority.length;
    final headChars = (budget * 3) ~/ 5;
    final tailChars = budget - headChars;
    return normalized.substring(0, headChars) +
        _omissionMarker +
        middlePriority +
        _priorityMarker +
        normalized.substring(normalized.length - tailChars);
  }
}
