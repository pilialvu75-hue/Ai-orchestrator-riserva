import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Presentation-only progress for the Cantiere project bar.
///
/// Authoritative project/task progress remains owned by the project plan. This
/// presenter exposes only a bounded fraction inside the current task so the UI
/// can visibly move through Architect -> Engineer -> Reviewer -> Validation.
///
/// The stage fraction never reaches the next completed-task boundary. A task is
/// still complete only after the authoritative plan advances.
final class WorkshopProgressPresentation {
  const WorkshopProgressPresentation._();

  static double displayValue({
    required double authoritativeProgress,
    required int completedTasks,
    required int totalTasks,
    required WorkshopStage? stage,
  }) {
    final base = authoritativeProgress.clamp(0.0, 1.0).toDouble();
    if (totalTasks <= 0) return base;

    final boundedCompleted = completedTasks.clamp(0, totalTasks).toInt();
    final completedRatio =
        (boundedCompleted / totalTasks).clamp(0.0, 1.0).toDouble();
    final authoritativeBase =
        completedRatio > base ? completedRatio : base;

    if (boundedCompleted >= totalTasks) return 1.0;

    final fraction = _stageFraction(stage);
    if (fraction <= 0) return authoritativeBase;

    final staged = ((boundedCompleted + fraction) / totalTasks)
        .clamp(0.0, 1.0)
        .toDouble();
    return staged > authoritativeBase ? staged : authoritativeBase;
  }

  static double _stageFraction(WorkshopStage? stage) {
    return switch (stage) {
      WorkshopStage.requested => 0.05,
      WorkshopStage.analysis => 0.20,
      WorkshopStage.planning => 0.35,
      WorkshopStage.implementation => 0.55,
      WorkshopStage.review => 0.75,
      WorkshopStage.validation => 0.90,
      WorkshopStage.completed => 0.95,
      WorkshopStage.blocked ||
      WorkshopStage.cancelled ||
      null => 0.0,
    };
  }
}
