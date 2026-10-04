/// Durable owner prompt captured before Cantiere inference starts.
///
/// A draft is intentionally not a Workshop project: project creation remains
/// gated by an approved proposal. The draft only guarantees that a process
/// crash cannot erase the owner's submitted instruction before that boundary.
final class WorkshopPendingPromptDraft {
  const WorkshopPendingPromptDraft({
    required this.instruction,
    required this.title,
    required this.updatedAt,
  });

  final String instruction;
  final String title;
  final DateTime updatedAt;
}
