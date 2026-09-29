import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_checkpoint_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Web storage reopens the canonical persistent checkpoint catalogue',
      () async {
    final first = await WorkshopWebCheckpointStorage.open();
    const jobId = 'web-storage-test:project-1';
    final checkpoint = WorkshopBackgroundCheckpoint(
      jobId: jobId,
      requestId: 'request-1',
      status: WorkshopBackgroundStatus.running,
      updatedAt: DateTime.utc(2026, 9, 29, 0, 30),
      projectId: 'project:request-1',
      taskId: 'task:implementation',
      completedTasks: 1,
      totalTasks: 3,
      message: 'durable-web-test',
    );

    await first.save(checkpoint);

    final reopened = await WorkshopWebCheckpointStorage.open();
    final recovered = await reopened.load(jobId);

    expect(recovered, isNotNull);
    expect(recovered!.projectId, checkpoint.projectId);
    expect(recovered.taskId, checkpoint.taskId);
    expect(recovered.completedTasks, 1);
    expect(recovered.totalTasks, 3);
    expect(recovered.status, WorkshopBackgroundStatus.running);
  });

  test('Web persistent catalogue keeps independent checkpoints isolated',
      () async {
    final store = await WorkshopWebCheckpointStorage.open();
    await store.save(
      WorkshopBackgroundCheckpoint(
        jobId: 'web-storage-test:a',
        requestId: 'request-a',
        status: WorkshopBackgroundStatus.running,
        updatedAt: DateTime.utc(2026, 9, 29, 0, 31),
      ),
    );
    await store.save(
      WorkshopBackgroundCheckpoint(
        jobId: 'web-storage-test:b',
        requestId: 'request-b',
        status: WorkshopBackgroundStatus.completed,
        updatedAt: DateTime.utc(2026, 9, 29, 0, 32),
      ),
    );

    final all = await store.loadAll();
    expect(all.map((item) => item.jobId), containsAll(<String>[
      'web-storage-test:a',
      'web-storage-test:b',
    ]));

    await store.remove('web-storage-test:a');
    expect(await store.load('web-storage-test:a'), isNull);
    expect(await store.load('web-storage-test:b'), isNotNull);
  });
}
