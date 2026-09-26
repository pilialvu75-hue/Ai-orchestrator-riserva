import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_progress_presentation.dart';

void main() {
  group('WorkshopProgressPresentation', () {
    test('shows intermediate progress for a one-task project', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0,
          completedTasks: 0,
          totalTasks: 1,
          stage: WorkshopStage.analysis,
        ),
        closeTo(0.20, 0.0001),
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0,
          completedTasks: 0,
          totalTasks: 1,
          stage: WorkshopStage.implementation,
        ),
        closeTo(0.55, 0.0001),
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0,
          completedTasks: 0,
          totalTasks: 1,
          stage: WorkshopStage.validation,
        ),
        closeTo(0.90, 0.0001),
      );
    });

    test('interpolates only the current task in multi-task projects', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0.25,
          completedTasks: 1,
          totalTasks: 4,
          stage: WorkshopStage.validation,
        ),
        closeTo(0.475, 0.0001),
      );
    });

    test('blocked UI can retain the last operational stage', () {
      const state = WorkshopDashboardControllerState(
        stage: WorkshopStage.blocked,
        lastOperationalStage: WorkshopStage.implementation,
        progress: 0,
        completedTasks: 0,
        totalTasks: 1,
      );

      expect(
        state.progressPresentationStage,
        WorkshopStage.implementation,
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: state.progress,
          completedTasks: state.completedTasks,
          totalTasks: state.totalTasks,
          stage: state.progressPresentationStage,
        ),
        closeTo(0.55, 0.0001),
      );
    });

    test('never changes authoritative completion semantics', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0.5,
          completedTasks: 1,
          totalTasks: 2,
          stage: WorkshopStage.blocked,
        ),
        0.5,
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 1,
          completedTasks: 2,
          totalTasks: 2,
          stage: WorkshopStage.completed,
        ),
        1,
      );
    });
  });
}
