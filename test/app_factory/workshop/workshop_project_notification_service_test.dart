import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_notification_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('surface keeps 100% task completion in build state until build result',
      () {
    const state = WorkshopDashboardControllerState(
      requestId: 'request-1',
      projectId: 'project:1',
      projectTitle: 'Contatore Test',
      projectStatus: WorkshopProjectStatus.completed,
      progress: 1,
      completedTasks: 2,
      totalTasks: 2,
    );

    final snapshot =
        WorkshopProjectSurfaceSnapshot.fromDashboardState(state);

    expect(snapshot.status, WorkshopProjectSurfaceStatus.build);
    expect(snapshot.shouldRetainSession, isTrue);
    expect(snapshot.progressPercent, 100);
  });

  test('surface treats an explicit project error as terminal', () {
    const state = WorkshopDashboardControllerState(
      requestId: 'request-2',
      projectId: 'project:2',
      projectTitle: 'Contatore Test',
      projectStatus: WorkshopProjectStatus.inProgress,
      progress: 0.5,
      completedTasks: 1,
      totalTasks: 2,
      lastError: 'planning failed',
    );

    final snapshot =
        WorkshopProjectSurfaceSnapshot.fromDashboardState(state);

    expect(snapshot.status, WorkshopProjectSurfaceStatus.failed);
    expect(snapshot.shouldRetainSession, isFalse);
    expect(snapshot.terminalOutcome, 'failed');
  });

  test('successful final build becomes terminal completed surface', () {
    final now = DateTime.utc(2026, 9, 30);
    final state = WorkshopDashboardControllerState(
      requestId: 'request-3',
      projectId: 'project:3',
      projectTitle: 'Contatore Test',
      projectStatus: WorkshopProjectStatus.completed,
      progress: 1,
      completedTasks: 2,
      totalTasks: 2,
      lastBuildResult: WorkshopBuildResult(
        requestId: 'build-3',
        target: WorkshopBuildTarget.android,
        status: WorkshopBuildStatus.succeeded,
        startedAt: now,
        finishedAt: now,
        artifactPath: '/tmp/app.apk',
      ),
    );

    final snapshot =
        WorkshopProjectSurfaceSnapshot.fromDashboardState(state);

    expect(snapshot.status, WorkshopProjectSurfaceStatus.completed);
    expect(snapshot.shouldRetainSession, isFalse);
  });

  test('Android notification service begins, updates and finishes project',
      () async {
    const channel = MethodChannel('test/workshop_project_notification');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object>{'ok': true};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    var permissionRequests = 0;
    final service = WorkshopProjectNotificationService(
      channel: channel,
      platformOverride: TargetPlatform.android,
      permissionRequester: () async {
        permissionRequests += 1;
      },
    );

    await service.sync(
      const WorkshopDashboardControllerState(
        requestId: 'request-4',
        projectId: 'project:4',
        projectTitle: 'Contatore Test',
        projectStatus: WorkshopProjectStatus.inProgress,
        progress: 0.25,
        completedTasks: 1,
        totalTasks: 4,
      ),
    );
    await service.sync(
      const WorkshopDashboardControllerState(
        requestId: 'request-4',
        projectId: 'project:4',
        projectTitle: 'Contatore Test',
        projectStatus: WorkshopProjectStatus.inProgress,
        progress: 0.5,
        completedTasks: 2,
        totalTasks: 4,
      ),
    );
    await service.sync(
      WorkshopDashboardControllerState(
        requestId: 'request-4',
        projectId: 'project:4',
        projectTitle: 'Contatore Test',
        projectStatus: WorkshopProjectStatus.completed,
        progress: 1,
        completedTasks: 4,
        totalTasks: 4,
        lastBuildResult: WorkshopBuildResult(
          requestId: 'build-4',
          target: WorkshopBuildTarget.android,
          status: WorkshopBuildStatus.succeeded,
          startedAt: DateTime.utc(2026, 9, 30),
          finishedAt: DateTime.utc(2026, 9, 30),
          artifactPath: '/tmp/app.apk',
        ),
      ),
    );

    expect(permissionRequests, 1);
    expect(
      calls.map((call) => call.method),
      <String>[
        'beginWorkshopProject',
        'updateWorkshopProject',
        'finishWorkshopProject',
      ],
    );
    final update = calls[1].arguments! as Map<Object?, Object?>;
    expect(update['progress'], 50);
    expect(update['completedTasks'], 2);
    expect(update['totalTasks'], 4);
  });
}
