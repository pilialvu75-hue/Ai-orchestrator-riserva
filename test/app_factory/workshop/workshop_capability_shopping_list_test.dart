import 'package:ai_orchestrator/app_factory/workshop/workshop_capability_shopping_list.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const builder = WorkshopCapabilityShoppingListBuilder();
  final approvedAt = DateTime.utc(2026, 9, 12, 8, 30);

  WorkshopProjectApprovalEvidence approvalFor(String projectId) =>
      WorkshopProjectApprovalEvidence(
        projectId: projectId,
        approvalId: 'approval:$projectId',
        approvedAt: approvedAt,
        approvedBy: 'owner',
      );

  WorkshopProjectPlan plan({
    String id = 'project:shopping',
    WorkshopProjectStatus status = WorkshopProjectStatus.planned,
    String goal = 'Build an Android application.',
    List<String> requirements = const <String>[],
    List<String> constraints = const <String>[],
    List<String> technologies = const <String>[],
    List<String> hardware = const <String>[],
    List<String> deliverables = const <String>[],
    List<String> validationCriteria = const <String>[],
    List<WorkshopProjectPhase> phases = const <WorkshopProjectPhase>[],
    List<WorkshopProjectTask> tasks = const <WorkshopProjectTask>[],
  }) =>
      WorkshopProjectPlan(
        id: id,
        title: 'Shopping list test',
        goal: goal,
        status: status,
        requirements: requirements,
        constraints: constraints,
        technologies: technologies,
        hardware: hardware,
        deliverables: deliverables,
        validationCriteria: validationCriteria,
        phases: phases,
        tasks: tasks,
      );

  test('requires explicit approval evidence and rejects draft projects', () {
    final project = plan(status: WorkshopProjectStatus.draft);

    expect(
      () => builder.build(
        plan: project,
        approval: approvalFor(project.id),
      ),
      throwsStateError,
    );
  });

  test('rejects approval evidence belonging to a different project', () {
    final project = plan();

    expect(
      () => builder.build(
        plan: project,
        approval: approvalFor('project:other'),
      ),
      throwsStateError,
    );
  });

  test('derives vendor-neutral voice, inference and storage capabilities', () {
    final project = plan(
      goal: 'Build an Android voice assistant that works offline.',
      requirements: const <String>[
        'Speech to text input and text to speech output are required.',
        'Use secure storage for API credentials.',
        'Provide local LLM inference with GGUF models.',
      ],
    );

    final result = builder.build(
      plan: project,
      approval: approvalFor(project.id),
    );

    final ids = result.needs.map((item) => item.capabilityId).toSet();
    expect(ids, contains(WorkshopLibraryCapabilityIds.voiceStt));
    expect(ids, contains(WorkshopLibraryCapabilityIds.voiceTts));
    expect(ids, contains(WorkshopLibraryCapabilityIds.storageSecrets));
    expect(ids, contains(WorkshopLibraryCapabilityIds.aiLocalInference));
    expect(result.targets, contains('android'));

    for (final need in result.needs) {
      expect(need.preferredContractId, startsWith('${need.capabilityId}.v'));
      expect(need.required, isTrue);
      expect(need.evidence, isNotEmpty);
    }
  });

  test('technology-only evidence is advisory rather than mandatory', () {
    final project = plan(
      goal: 'Build an Android utility.',
      technologies: const <String>['SQLite'],
    );

    final result = builder.build(
      plan: project,
      approval: approvalFor(project.id),
    );

    final localDb = result.needs.singleWhere(
      (item) => item.capabilityId == WorkshopLibraryCapabilityIds.storageLocalDb,
    );
    expect(localDb.required, isFalse);
    expect(localDb.priority, WorkshopProjectPriority.normal);
  });

  test('task priority is preserved when it is strongest evidence', () {
    final project = plan(
      tasks: <WorkshopProjectTask>[
        WorkshopProjectTask(
          id: 'task:logging',
          title: 'Diagnostics',
          description: 'Add structured logging and crash logs.',
          phaseId: 'phase:quality',
          priority: WorkshopProjectPriority.critical,
        ),
      ],
    );

    final result = builder.build(
      plan: project,
      approval: approvalFor(project.id),
    );

    final diagnostics = result.needs.singleWhere(
      (item) => item.capabilityId == WorkshopLibraryCapabilityIds.diagnosticsLogging,
    );
    expect(diagnostics.priority, WorkshopProjectPriority.critical);
    expect(diagnostics.required, isFalse);
  });

  test('preserves unmapped architectural inputs instead of guessing', () {
    final project = plan(
      requirements: const <String>[
        'The application must support a proprietary quantum-widget bus.',
      ],
    );

    final result = builder.build(
      plan: project,
      approval: approvalFor(project.id),
    );

    expect(
      result.unmappedInputs,
      contains('The application must support a proprietary quantum-widget bus.'),
    );
  });

  test('output is deterministic for the same approved project', () {
    final project = plan(
      goal: 'Build a Windows and Android app with REST API access.',
      requirements: const <String>['HTTP API client is required.'],
    );
    final approval = approvalFor(project.id);

    final first = builder.build(plan: project, approval: approval).toJson();
    final second = builder.build(plan: project, approval: approval).toJson();

    expect(second, first);
  });
}
