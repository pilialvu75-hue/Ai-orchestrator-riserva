/// Shared bounded projection of the Architect plan used by every downstream
/// Cantiere role that can enforce the current task contract.
///
/// Engineer, Reviewer and Validation MUST consume the same projection. This
/// prevents a gate from rejecting an implementation for requirements that were
/// present only in a longer Architect response the Engineer never received.
///
/// The tail is deliberately preserved because Architect responses commonly put
/// validation/acceptance criteria at the end of the plan.
abstract final class WorkshopTaskPlanProjection {
  static const int maxChars = 900;
  static const String _omissionMarker = '\n...[bounded middle omitted]...\n';

  static String project(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.length <= maxChars) {
      return normalized;
    }

    final remaining = maxChars - _omissionMarker.length;
    final headChars = (remaining * 3) ~/ 5;
    final tailChars = remaining - headChars;

    return normalized.substring(0, headChars) +
        _omissionMarker +
        normalized.substring(normalized.length - tailChars);
  }
}
