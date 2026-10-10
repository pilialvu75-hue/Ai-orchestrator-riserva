import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Cantiere Web projects survive storage reopen without chat mixing',
      () async {
    final now = DateTime.utc(2026, 10, 9, 18);
    final storage = await WorkshopWebProjectStorage.open();

    await storage.save(<WorkshopWebProject>[
      WorkshopWebProject(
        id: 'web-project:1',
        title: 'Cammina',
        goal: 'Traccia una camminata.',
        platforms: const <String>['Android', 'Web'],
        status: WorkshopWebProjectStatus.proposalReady,
        progress: 0.10,
        currentPhase: 'Proposta pronta',
        currentItem: 'Attende approvazione del proprietario',
        createdAt: now,
        updatedAt: now,
        proposal: 'MVP pronto per approvazione.',
      ),
    ]);

    final reopened = await WorkshopWebProjectStorage.open();
    final projects = await reopened.loadAll();

    expect(projects, hasLength(1));
    expect(projects.single.title, 'Cammina');
    expect(projects.single.platforms, <String>['Android', 'Web']);
    expect(projects.single.status, WorkshopWebProjectStatus.proposalReady);
    expect(projects.single.progress, 0.10);
    expect(projects.single.proposal, 'MVP pronto per approvazione.');
  });
}
