import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Presentation-only progress for the Cantiere project bar.
///
/// The main progress percentage reflects only persisted task completion.
/// Current inference stages are displayed separately by the stage ribbon.
/// A failed review, retry, cancellation or restart cannot invent progress.
final class WorkshopProgressPresentation {
  const WorkshopProgressPresentation._();

  static double displayValue({
    required double authoritativeProgress,
    required int completedTasks,
    required int totalTasks,
    required WorkshopStage? stage,
    WorkshopStage? actualStage,
  }) {
    if (totalTasks <= 0) {
      // A project without known tasks has no measurable task progress.
      return 0.0;
    }
    return completedTasks.clamp(0, totalTasks).toDouble() / totalTasks;
  }
}
