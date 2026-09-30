import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Presentation-only progress for the Cantiere project bar.
///
/// Authoritative project/task completion remains owned by the project plan.
/// While one task is actively moving through the runtime pipeline, this
/// presenter exposes a bounded fraction inside that task so the user can see
/// Architect -> Engineer -> Reviewer -> Validation progress.
///
/// A stage fraction never reaches the next completed-task boundary. Blocked,
/// cancelled and terminal project stages never fabricate additional progress.
final class WorkshopProgressPresentation {
  const WorkshopProgressPresentation._();

  static double displayValue({
    required double authoritativeProgress,
    required int completedTasks,
    required int totalTasks,
    required WorkshopStage? stage,
    WorkshopStage? actualStage,
  }) {
    final base = authoritativeProgress.clamp(0.0, 1.0).toDouble();
    if (totalTasks <= 0) return base;

    final boundedCompleted = completedTasks.clamp(0, totalTasks).toInt();
    final completedRatio =
        (boundedCompleted / totalTasks).clamp(0.0, 1.0).toDouble();
    final authoritativeBase =
        completedRatio > base ? completedRatio : base;

    if (boundedCompleted >= totalTasks) return 1.0;

    final currentStage = actualStage ?? stage;
    if (currentStage == WorkshopStage.blocked ||
        currentStage == WorkshopStage.cancelled) {
      return authoritativeBase;
    }

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
