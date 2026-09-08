import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_dashboard_page.dart';

void main() {
  group('WorkshopProductionActionState', () {
    test('exposes run only after dashboard prepared a task', () {
      final none = WorkshopProductionActionState.resolve(
        hasPreparedTask: false,
        hasBoundHandle: false,
        inferenceReadyForApproval: false,
        sessionStatus: null,
        projectReadyForBuild: false,
        isBusy: false,
      );

      expect(none.action, WorkshopProductionUiAction.none);
      expect(none.enabled, isFalse);

      final run = WorkshopProductionActionState.resolve(
        hasPreparedTask: true,
        hasBoundHandle: false,
        inferenceReadyForApproval: false,
        sessionStatus: null,
        projectReadyForBuild: false,
        isBusy: false,
      );

      expect(run.action, WorkshopProductionUiAction.run);
      expect(run.enabled, isTrue);
    });

    test('never exposes owner review before successful validation', () {
      final state = WorkshopProductionActionState.resolve(
        hasPreparedTask: true,
        hasBoundHandle: true,
        inferenceReadyForApproval: false,
        sessionStatus: WorkspaceSessionStatus.validation,
        projectReadyForBuild: false,
        isBusy: false,
      );

      expect(state.action, WorkshopProductionUiAction.none);
      expect(state.enabled, isFalse);
    });

    test('successful validation exposes explicit review decision only', () {
      final state = WorkshopProductionActionState.resolve(
        hasPreparedTask: true,
        hasBoundHandle: true,
        inferenceReadyForApproval: true,
        sessionStatus: WorkspaceSessionStatus.validation,
        projectReadyForBuild: false,
        isBusy: false,
      );

      expect(state.action, WorkshopProductionUiAction.review);
      expect(state.enabled, isTrue);
      expect(state.label, contains('decidi'));
    });

    test('apply becomes available only for an approved session', () {
      final state = WorkshopProductionActionState.resolve(
        hasPreparedTask: true,
        hasBoundHandle: true,
        inferenceReadyForApproval: true,
        sessionStatus: WorkspaceSessionStatus.approved,
        projectReadyForBuild: false,
        isBusy: false,
      );

      expect(state.action, WorkshopProductionUiAction.apply);
      expect(state.enabled, isTrue);
      expect(state.label, contains('Applica'));
    });

    test('final build is exposed only after the project has no active task', () {
      final build = WorkshopProductionActionState.resolve(
        hasPreparedTask: false,
        hasBoundHandle: false,
        inferenceReadyForApproval: false,
        sessionStatus: null,
        projectReadyForBuild: true,
        isBusy: false,
      );

      expect(build.action, WorkshopProductionUiAction.build);
      expect(build.enabled, isTrue);
      expect(build.label, contains('APK'));

      final stillWorking = WorkshopProductionActionState.resolve(
        hasPreparedTask: true,
        hasBoundHandle: true,
        inferenceReadyForApproval: true,
        sessionStatus: WorkspaceSessionStatus.approved,
        projectReadyForBuild: true,
        isBusy: false,
      );

      expect(stillWorking.action, WorkshopProductionUiAction.apply);
      expect(stillWorking.enabled, isTrue);
    });

    test('blocked, completed and busy sessions expose no mutation action', () {
      for (final status in <WorkspaceSessionStatus>[
        WorkspaceSessionStatus.blocked,
        WorkspaceSessionStatus.completed,
        WorkspaceSessionStatus.cancelled,
      ]) {
        final state = WorkshopProductionActionState.resolve(
          hasPreparedTask: true,
          hasBoundHandle: true,
          inferenceReadyForApproval: true,
          sessionStatus: status,
          projectReadyForBuild: false,
          isBusy: false,
        );

        expect(state.action, WorkshopProductionUiAction.none);
        expect(state.enabled, isFalse);
      }

      final busy = WorkshopProductionActionState.resolve(
        hasPreparedTask: false,
        hasBoundHandle: false,
        inferenceReadyForApproval: false,
        sessionStatus: null,
        projectReadyForBuild: true,
        isBusy: true,
      );

      expect(busy.action, WorkshopProductionUiAction.none);
      expect(busy.enabled, isFalse);
    });
  });
}
