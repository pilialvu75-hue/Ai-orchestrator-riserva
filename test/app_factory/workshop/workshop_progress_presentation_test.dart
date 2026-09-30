import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_progress_presentation.dart';

void main() {
  group('WorkshopProgressPresentation', () {
    test('shows bounded progress inside the active task', () {
      final requested = WorkshopProgressPresentation.displayValue(
        authoritativeProgress: 0,
        completedTasks: 0,
        totalTasks: 2,
        stage: WorkshopStage.requested,
      );
      final implementation = WorkshopProgressPresentation.displayValue(
        authoritativeProgress: 0,
        completedTasks: 0,
        totalTasks: 2,
        stage: WorkshopStage.implementation,
      );
      final validation = WorkshopProgressPresentation.displayValue(
        authoritativeProgress: 0,
        completedTasks: 0,
        totalTasks: 2,
        stage: WorkshopStage.validation,
      );

      expect(requested, greaterThan(0));
      expect(implementation, greaterThan(requested));
      expect(validation, greaterThan(implementation));
      expect(validation, lessThan(0.5));
    });

    test('advances from real completed task count', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 1 / 3,
          completedTasks: 1,
          totalTasks: 3,
          stage: WorkshopStage.planning,
        ),
        closeTo(1 / 3, 0.0001),
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 2 / 3,
          completedTasks: 2,
          totalTasks: 3,
          stage: WorkshopStage.validation,
        ),
        closeTo(2 / 3, 0.0001),
      );
    });

    test('completed task count can repair stale presentation progress', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0,
          completedTasks: 1,
          totalTasks: 4,
          stage: WorkshopStage.blocked,
        ),
        0.25,
      );
    });

    test('prepared engine stage stays presentation-only', () {
      const state = WorkshopDashboardControllerState(
        stage: WorkshopStage.implementation,
        lastOperationalStage: WorkshopStage.requested,
        progress: 0,
        completedTasks: 0,
        totalTasks: 3,
      );

      expect(state.progressPresentationStage, WorkshopStage.requested);
      final displayed = WorkshopProgressPresentation.displayValue(
        authoritativeProgress: state.progress,
        completedTasks: state.completedTasks,
        totalTasks: state.totalTasks,
        stage: state.progressPresentationStage,
      );
      expect(displayed, greaterThan(0));
      expect(displayed, lessThan(1 / 3));
    });

    test('blocked UI can retain the last operational stage without fake progress',
        () {
      const state = WorkshopDashboardControllerState(
        stage: WorkshopStage.blocked,
        lastOperationalStage: WorkshopStage.implementation,
        progress: 0,
        completedTasks: 0,
        totalTasks: 3,
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
        0,
      );
    });

    test('preserves authoritative completion', () {
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
