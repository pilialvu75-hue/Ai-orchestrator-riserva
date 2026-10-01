import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';

void main() {
  group('WorkshopProjectExecutor task operation routing', () {
    test('Contatore Test project keeps initial implementation as create', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/main.dart': 'starter'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:counter-test',
        title: 'Contatore Test',
        goal: 'Crea una semplice app Contatore Test.',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:implementation',
            title: 'Implementation',
            description: 'Implement product tasks',
            taskIds: const <String>['task:initial-implementation'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:initial-implementation',
            title: 'Funzionalità principale',
            description:
                'Implement the requested behavior. Project goal: Crea una app Contatore Test.',
            phaseId: 'phase:implementation',
            affectedPaths: const <String>['lib/main.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:counter-test',
        title: 'Contatore Test',
        instruction: 'Crea una semplice app Contatore Test.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(
        session!.context.request.operation,
        WorkshopOperation.create,
      );
    });



    test('create root task repairs persisted scope with lib/main.dart',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:persisted-create-scope',
        title: 'Contatore Test',
        goal: 'Create the app',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:dynamic',
            title: 'Implementation',
            description: 'Implement product',
            taskIds: const <String>['task:scope:counter-ui'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:scope:counter-ui',
            title: 'Counter UI',
            description: 'Create the Flutter counter UI.',
            phaseId: 'phase:dynamic',
            affectedPaths: const <String>['lib/app.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:persisted-create-scope',
        title: 'Contatore Test',
        instruction: 'Create a new Flutter counter app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(
        session!.context.request.targetFiles,
        <String>['lib/main.dart', 'lib/app.dart'],
      );
      expect(
        session.context.request.context,
        contains('Task target files: lib/main.dart | lib/app.dart'),
      );
    });

    test('create follow-up task keeps lib/main.dart in hard scope',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/main.dart': 'existing app'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:create-followup-scope',
        title: 'Manga Kids',
        goal: 'Create the app',
        status: WorkshopProjectStatus.inProgress,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:dynamic',
            title: 'Implementation',
            description: 'Implement product',
            taskIds: const <String>['task:first', 'task:followup'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:first',
            title: 'Initial app',
            description: 'Materialize the initial app.',
            phaseId: 'phase:dynamic',
            affectedPaths: const <String>['lib/main.dart'],
            completed: true,
          ),
          WorkshopProjectTask(
            id: 'task:followup',
            title: 'Follow-up UI',
            description: 'Complete the requested UI.',
            phaseId: 'phase:dynamic',
            dependencies: const <String>['task:first'],
            affectedPaths: const <String>['lib/app.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:create-followup-scope',
        title: 'Manga Kids',
        instruction: 'Create a new Flutter app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(session!.context.request.operation, WorkshopOperation.create);
      expect(
        session.context.request.targetFiles,
        <String>['lib/main.dart', 'lib/app.dart'],
      );
    });

    test('dynamic dependency-free root task inherits owner create operation',
        () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:dynamic-root',
        title: 'Dynamic root',
        goal: 'Create the app',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:dynamic',
            title: 'Implementation',
            description: 'Implement product',
            taskIds: const <String>['task:scope:update-app'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:scope:update-app',
            title: 'Update app',
            description: 'Update the app implementation safely.',
            phaseId: 'phase:dynamic',
            affectedPaths: const <String>['lib/main.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:dynamic-root',
        title: 'New app',
        instruction: 'Create a new Flutter app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(session!.context.request.operation, WorkshopOperation.create);
    });

    test('scoped acceptance task still routes to validate', () async {
      final gateway = _RecordingGateway(files: <String, String>{});
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:scoped-acceptance',
        title: 'Scoped acceptance',
        goal: 'Verify app',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:scoped',
            title: 'Verification',
            description: 'Verify product',
            taskIds: const <String>['task:scope:acceptance-verification'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:scope:acceptance-verification',
            title: 'Polish',
            description: 'Polish final output.',
            phaseId: 'phase:scoped',
            affectedPaths: const <String>['test/widget_test.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:scoped-acceptance',
        title: 'Product',
        instruction: 'Create product',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(session!.context.request.operation, WorkshopOperation.validate);
    });

    test('acceptance task routes to validate regardless of wording', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'test/widget_test.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:acceptance',
        title: 'Acceptance project',
        goal: 'Ship safely',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:implementation',
            title: 'Implementation',
            description: 'Verify product',
            taskIds: const <String>['task:acceptance-verification'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:acceptance-verification',
            title: 'Verifica e rifinitura',
            description: 'Add or update focused verification.',
            phaseId: 'phase:implementation',
            affectedPaths: const <String>['test/widget_test.dart'],
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:acceptance',
        title: 'Product',
        instruction: 'Create product',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(
        session!.context.request.operation,
        WorkshopOperation.validate,
      );
    });

    test('build repair task routes to fix instead of inherited create', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/main.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final plan = WorkshopProjectPlan(
        id: 'project:repair',
        title: 'Repair',
        goal: 'Repair build',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:implementation',
            title: 'Repair',
            description: 'Repair',
            taskIds: const <String>['task:initial-implementation'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:initial-implementation',
            title: 'Correzione build mirata',
            description: 'BUILD REPAIR ATTEMPT: 1 Fix analyzer failure.',
            phaseId: 'phase:implementation',
          ),
        ],
      );
      const projectRequest = WorkshopRequest(
        id: 'dashboard:repair',
        title: 'Repair',
        instruction: 'Repair build',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      );

      final session = await executor.prepareNextTask(
        plan,
        projectRequest: projectRequest,
      );

      expect(session, isNotNull);
      expect(session!.context.request.operation, WorkshopOperation.fix);
    });
  });

  group('WorkshopProjectExecutor project isolation', () {
    test('same task id never reuses a session from another project', () async {
      final alphaGateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'alpha'},
      );
      final betaGateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'beta'},
      );
      final fallback = _RecordingGateway(files: <String, String>{});

      final executor = WorkshopProjectExecutor(
        gateway: fallback,
        projectGatewayFactory: (projectId) {
          if (projectId == 'project:alpha') return alphaGateway;
          if (projectId == 'project:beta') return betaGateway;
          throw StateError('Unexpected project: $projectId');
        },
        projectWorkspacePathResolver: (projectId) => '/workspaces/$projectId',
      );

      final alpha = _planForProject('project:alpha');
      final beta = _planForProject('project:beta');

      final alphaSession = await executor.prepareNextTask(alpha);
      expect(alphaSession, isNotNull);
      expect(alphaSession!.workspace.read('lib/app.dart'), 'alpha');

      final betaSession = await executor.prepareNextTask(beta);
      expect(betaSession, isNotNull);
      expect(betaSession!.workspace.read('lib/app.dart'), 'beta');
      expect(identical(alphaSession, betaSession), isFalse);
      expect(identical(executor.sessionForTask('task:shared'), betaSession), isTrue);
      expect(
        executor.workspacePathForProject('project:beta'),
        '/workspaces/project:beta',
      );
    });
    test('repair plan can inherit the failed project workspace', () async {
      final sourceGateway = _RecordingGateway(
        files: <String, String>{'lib/main.dart': 'failed source'},
      );
      final fallback = _RecordingGateway(files: <String, String>{});

      final executor = WorkshopProjectExecutor(
        gateway: fallback,
        projectGatewayFactory: (projectId) {
          if (projectId == 'project:source') return sourceGateway;
          throw StateError('Unexpected workspace identity: $projectId');
        },
        projectWorkspacePathResolver: (projectId) => '/workspaces/$projectId',
      );

      final repairPlan = WorkshopProjectPlan(
        id: 'project:repair-cycle',
        title: 'Repair',
        goal: 'Fix the failed build',
        workspaceProjectId: 'project:source',
        status: WorkshopProjectStatus.planned,
        phases: <WorkshopProjectPhase>[
          WorkshopProjectPhase(
            id: 'phase:implementation',
            title: 'Repair',
            description: 'Repair one build failure',
            taskIds: const <String>['task:initial-implementation'],
          ),
        ],
        tasks: <WorkshopProjectTask>[
          WorkshopProjectTask(
            id: 'task:initial-implementation',
            title: 'Correzione build mirata',
            description: 'BUILD REPAIR ATTEMPT: 1 Fix syntax.',
            phaseId: 'phase:implementation',
          ),
        ],
      );

      final session = await executor.prepareNextTask(repairPlan);

      expect(session, isNotNull);
      expect(session!.workspace.read('lib/main.dart'), 'failed source');
      expect(
        executor.workspacePathForProject(
          repairPlan.effectiveWorkspaceProjectId,
        ),
        '/workspaces/project:source',
      );
    });
  });

  group('WorkshopProjectExecutor.applyApprovedTask', () {
    test('applies only an approved task and completes its workspace session',
        () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final session = await executor.prepareTask(_plan(), 'task:apply');

      session.workspace.write(
        path: 'lib/app.dart',
        content: 'new',
      );
      session.beginReview();
      session.beginValidation();
      const WorkshopApplyApprovalGate().decide(
        session: session,
        decision: WorkshopApplyDecision.approve,
      );

      final applied = await executor.applyApprovedTask('task:apply');

      expect(identical(applied, session), isTrue);
      expect(session.status, WorkspaceSessionStatus.completed);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.files['lib/app.dart'], 'new');
      expect(gateway.writeCalls, 1);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });

    test('cannot bypass explicit approval', () async {
      final gateway = _RecordingGateway(
        files: <String, String>{'lib/app.dart': 'old'},
      );
      final executor = WorkshopProjectExecutor(gateway: gateway);
      final session = await executor.prepareTask(_plan(), 'task:apply');

      session.workspace.write(
        path: 'lib/app.dart',
        content: 'new',
      );
      session.beginReview();
      session.beginValidation();

      await expectLater(
        executor.applyApprovedTask('task:apply'),
        throwsA(isA<StateError>()),
      );

      expect(session.status, WorkspaceSessionStatus.validation);
      expect(session.isApplyApproved, isFalse);
      expect(gateway.files['lib/app.dart'], 'old');
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
      expect(gateway.commitCalls, 0);
      expect(gateway.pushCalls, 0);
      expect(gateway.pullRequestCalls, 0);
    });
  });
}

WorkshopProjectPlan _planForProject(String projectId) {
  return WorkshopProjectPlan(
    id: projectId,
    title: projectId,
    goal: 'Keep project workspace isolated',
    status: WorkshopProjectStatus.planned,
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase:implementation',
        title: 'Implementation',
        description: 'One isolated task',
        taskIds: const <String>['task:shared'],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: 'task:shared',
        title: 'Modify project app',
        description: 'Modify only this project',
        phaseId: 'phase:implementation',
        affectedPaths: const <String>['lib/app.dart'],
      ),
    ],
  );
}

WorkshopProjectPlan _plan() {
  return WorkshopProjectPlan(
    id: 'project:apply',
    title: 'Apply project',
    goal: 'Apply the validated change',
    status: WorkshopProjectStatus.planned,
    phases: <WorkshopProjectPhase>[
      WorkshopProjectPhase(
        id: 'phase:implementation',
        title: 'Implementation',
        description: 'Apply one validated task',
        taskIds: const <String>['task:apply'],
      ),
    ],
    tasks: <WorkshopProjectTask>[
      WorkshopProjectTask(
        id: 'task:apply',
        title: 'Modify app',
        description: 'Modify the app file',
        phaseId: 'phase:implementation',
        affectedPaths: const <String>['lib/app.dart'],
      ),
    ],
  );
}

final class _RecordingGateway implements GitWorkspaceGateway {
  _RecordingGateway({required Map<String, String> files})
      : files = Map<String, String>.from(files);

  final Map<String, String> files;
  int writeCalls = 0;
  int deleteCalls = 0;
  int commitCalls = 0;
  int pushCalls = 0;
  int pullRequestCalls = 0;

  @override
  Future<GitWorkspaceInfo> openWorkspace() async => const GitWorkspaceInfo(
        repository: 'test/repository',
        branch: 'main',
      );

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<List<String>> listFiles({String? directory}) async =>
      files.keys.toList(growable: false);

  @override
  Future<void> createBranch(String branchName) async {}

  @override
  Future<void> writeFile({required String path, required String content}) async {
    writeCalls += 1;
    files[path] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    deleteCalls += 1;
    files.remove(path);
  }

  @override
  Future<GitWorkspaceDiff> getDiff() async =>
      const GitWorkspaceDiff(files: <GitWorkspaceFileChange>[]);

  @override
  Future<String> commit(String message) async {
    commitCalls += 1;
    return 'commit';
  }

  @override
  Future<void> push() async {
    pushCalls += 1;
  }

  @override
  Future<String> createPullRequest({
    required String title,
    required String body,
    required String headBranch,
    required String baseBranch,
  }) async {
    pullRequestCalls += 1;
    return 'pr';
  }
}
