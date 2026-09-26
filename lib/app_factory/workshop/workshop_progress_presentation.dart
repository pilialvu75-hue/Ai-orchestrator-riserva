import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Presentation-only progress for the Cantiere project bar.
///
/// [authoritativeProgress] remains the source of truth for completed tasks.
/// This helper only interpolates the currently active task from the observable
/// Workshop stage so a one-task project does not appear frozen at 0% until its
/// final guarded apply completes.
final class WorkshopProgressPresentation {
  const WorkshopProgressPresentation._();

  static double displayValue({
    required double authoritativeProgress,
    required int completedTasks,
    required int totalTasks,
    required WorkshopStage? stage,
  }) {
    final base = authoritativeProgress.clamp(0.0, 1.0).toDouble();
    if (totalTasks <= 0 || completedTasks >= totalTasks) {
      return base;
    }

    final stageFraction = _stageFraction(stage);
    if (stageFraction <= 0) {
      return base;
    }

    final boundedCompleted = completedTasks.clamp(0, totalTasks).toInt();
    final staged =
        ((boundedCompleted + stageFraction) / totalTasks).clamp(0.0, 1.0).toDouble();

    return staged > base ? staged : base;
  }

  static double _stageFraction(WorkshopStage? stage) {
    switch (stage) {
      case WorkshopStage.requested:
        return 0.05;
      case WorkshopStage.analysis:
        return 0.20;
      case WorkshopStage.planning:
        return 0.35;
      case WorkshopStage.implementation:
        return 0.55;
      case WorkshopStage.review:
        return 0.75;
      case WorkshopStage.validation:
        return 0.90;
      case WorkshopStage.completed:
        return 1.0;
      case WorkshopStage.blocked:
      case WorkshopStage.cancelled:
      case null:
        return 0.0;
    }
  }
}
