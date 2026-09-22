import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_background_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('concurrent store instances preserve independent checkpoint writes',
      () async {
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final projectStore = PersistentWorkshopCheckpointStore(
      preferences: preferences,
    );
    final durableStore = PersistentWorkshopCheckpointStore(
      preferences: preferences,
    );

    final now = DateTime.utc(2026, 9, 22, 8);
    await Future.wait(<Future<void>>[
      projectStore.save(
        WorkshopBackgroundCheckpoint(
          jobId: 'workshop-production:project:v2:project-1',
          requestId: 'request-1',
          status: WorkshopBackgroundStatus.running,
          updatedAt: now,
          projectId: 'project-1',
        ),
      ),
      durableStore.save(
        WorkshopBackgroundCheckpoint(
          jobId: 'workshop-durable-orchestrator:v1:project-1',
          requestId: 'correlation-1',
          status: WorkshopBackgroundStatus.paused,
          updatedAt: now.add(const Duration(milliseconds: 1)),
          projectId: 'project-1',
          taskId: 'ci',
        ),
      ),
    ]);

    final restored = await projectStore.loadAll();
    expect(
      restored.map((checkpoint) => checkpoint.jobId).toSet(),
      <String>{
        'workshop-production:project:v2:project-1',
        'workshop-durable-orchestrator:v1:project-1',
      },
    );
  });

  test('read waits behind an in-flight serialized mutation', () async {
    final preferences = PreferencesService(
      await SharedPreferences.getInstance(),
    );
    final first = PersistentWorkshopCheckpointStore(
      preferences: preferences,
    );
    final second = PersistentWorkshopCheckpointStore(
      preferences: preferences,
    );

    final save = first.save(
      WorkshopBackgroundCheckpoint(
        jobId: 'job-1',
        requestId: 'request-1',
        status: WorkshopBackgroundStatus.running,
        updatedAt: DateTime.utc(2026, 9, 22, 8),
      ),
    );
    final read = second.load('job-1');

    await save;
    expect(await read, isNotNull);
  });
}
