import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_progress_presentation.dart';

void main() {
  group('WorkshopProgressPresentation', () {
    test('no optimistic progress while any stage of a task is underway', () {
      for (final stage in <WorkshopStage>[
        WorkshopStage.requested,
        WorkshopStage.analysis,
        WorkshopStage.planning,
        WorkshopStage.implementation,
        WorkshopStage.review,
        WorkshopStage.validation,
      ]) {
        expect(
          WorkshopProgressPresentation.displayValue(
            authoritativeProgress: 0,
            completedTasks: 0,
            totalTasks: 2,
            stage: stage,
            actualStage: stage,
          ),
          0,
          reason: 'stage ${stage.name} cannot complete a task',
        );
      }
    });

    test('one completed task stays one completed task during retry or failure', () {
      for (final stage in <WorkshopStage>[
        WorkshopStage.planning,
        WorkshopStage.implementation,
        WorkshopStage.review,
        WorkshopStage.validation,
        WorkshopStage.blocked,
        WorkshopStage.cancelled,
      ]) {
        expect(
          WorkshopProgressPresentation.displayValue(
            authoritativeProgress: 0.98,
            completedTasks: 1,
            totalTasks: 3,
            stage: stage,
            actualStage: stage,
          ),
          closeTo(1 / 3, 1e-10),
        );
      }
    });

    test('persisted task count outranks stale presentation state', () {
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 0.95,
          completedTasks: 1,
          totalTasks: 4,
          stage: WorkshopStage.review,
        ),
        0.25,
      );
    });

    test('operational stage is reported separately from task completion', () {
      const state = WorkshopDashboardControllerState(
        stage: WorkshopStage.implementation,
        lastOperationalStage: WorkshopStage.requested,
        progress: 0,
        completedTasks: 0,
        totalTasks: 3,
      );
      expect(state.progressPresentationStage, WorkshopStage.requested);
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: state.progress,
          completedTasks: state.completedTasks,
          totalTasks: state.totalTasks,
          stage: state.progressPresentationStage,
          actualStage: state.stage,
        ),
        0,
      );
    });

    test('completed projects display 100 percent and invalid counts clamp', () {
      for (final counts in <List<int>>[
        <int>[2, 2],
        <int>[99, 2],
      ]) {
        expect(
          WorkshopProgressPresentation.displayValue(
            authoritativeProgress: 0,
            completedTasks: counts[0],
            totalTasks: counts[1],
            stage: WorkshopStage.completed,
          ),
          1,
        );
      }
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 1,
          completedTasks: -1,
          totalTasks: 2,
          stage: WorkshopStage.implementation,
        ),
        0,
      );
      expect(
        WorkshopProgressPresentation.displayValue(
          authoritativeProgress: 1,
          completedTasks: 0,
          totalTasks: 0,
          stage: WorkshopStage.requested,
        ),
        0,
      );
    });
  });
}
