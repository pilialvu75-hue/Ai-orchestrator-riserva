import 'package:ai_orchestrator/app_factory/workshop/workshop_execution.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_execution_resume_attempt.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkshopExecutionResumeAttemptCoordinator', () {
    test(
      'keeps execution identity, creates a new attempt and carries semantic checkpoint state across provider failover',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = PreferencesService(
          await SharedPreferences.getInstance(),
        );
        final store = WorkshopExecutionStore(preferences: preferences);
        const coordinator = WorkshopExecutionResumeAttemptCoordinator(
          executionStore: null,
        );
      },
    );
  });
}
