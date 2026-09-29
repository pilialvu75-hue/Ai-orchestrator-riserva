import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Presentation-only progress for the Cantiere project bar.
///
/// Progress is deliberately derived only from authoritative task completion.
/// [stage] is accepted so callers can keep presenting the operational stage
/// separately, but it never fabricates a fractional task completion.
final class WorkshopProgressPresentation {
  const WorkshopProgressPresentation._();

  static double displayValue({
    required double authoritativeProgress,
    required int completedTasks,
    required int totalTasks,
    required WorkshopStage? stage,
  }) {
    final base = authoritativeProgress.clamp(0.0, 1.0).toDouble();
    if (totalTasks <= 0) {
      return base;
    }

    final boundedCompleted = completedTasks.clamp(0, totalTasks).toInt();
    final completedRatio =
        (boundedCompleted / totalTasks).clamp(0.0, 1.0).toDouble();

    return completedRatio > base ? completedRatio : base;
  }
}
