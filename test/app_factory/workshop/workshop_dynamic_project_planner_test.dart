import 'dart:convert';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dynamic_project_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const decoder = WorkshopDynamicProjectPlanDecoder();

  test('accepts a bounded one-task plan and namespaces ids', () {
    final plan = decoder.decode(
      jsonEncode(<String, Object>{
        'phases': <Object>[
          <String, Object>{
            'id': 'implementation',
            'title': 'Implementation',
            'description': 'Implement the requested behavior.',
            'dependsOn': <String>[],
          },
        ],
        'tasks': <Object>[
          <String, Object>{
            'id': 'implement',
            'phaseId': 'implementation',
            'title': 'Implement',
            'description': 'Implement one bounded increment.',
            'dependsOn': <String>[],
            'affectedPaths': <String>['lib/app.dart'],
            'validationCriteria': <String>['Requested behavior works.'],
          },
        ],
      }),
      requestId: 'dashboard:123',
    );

    expect(plan.phases, hasLength(1));
    expect(plan.tasks, hasLength(1));
    expect(plan.phases.single.id, 'phase:dashboard-123:implementation');
    expect(plan.tasks.single.id, 'task:dashboard-123:implement');
    expect(
      plan.tasks.single.phaseId,
      'phase:dashboard-123:implementation',
    );
  });

  test('materializes phase ordering into executable task dependencies', () {
    final plan = decoder.decode(
      jsonEncode(<String, Object>{
        'phases': <Object>[
          <String, Object>{
            'id': 'foundation',
            'title': 'Foundation',
            'description': 'Build the foundation.',
            'dependsOn': <String>[],
          },
          <String, Object>{
            'id': 'verification',
            'title': 'Verification',
            'description': 'Verify the completed foundation.',
            'dependsOn': <String>['foundation'],
          },
        ],
        'tasks': <Object>[
          <String, Object>{
            'id': 'implement',
            'phaseId': 'foundation',
            'title': 'Implement',
            'description': 'Implement the feature.',
            'dependsOn': <String>[],
            'affectedPaths': <String>['lib/app.dart'],
            'validationCriteria': <String>['Feature is implemented.'],
          },
          <String, Object>{
            'id': 'test',
            'phaseId': 'verification',
            'title': 'Test',
            'description': 'Add focused verification.',
            'dependsOn': <String>[],
            'affectedPaths': <String>['test/widget_test.dart'],
            'validationCriteria': <String>['Focused test passes.'],
          },
        ],
      }),
      requestId: 'request-1',
    );

    final implement = plan.tasks.firstWhere(
      (task) => task.id.endsWith(':implement'),
    );
    final testTask = plan.tasks.firstWhere(
      (task) => task.id.endsWith(':test'),
    );

    expect(testTask.dependencies, contains(implement.id));
  });

  test('rejects dangling task dependency before execution', () {
    expect(
      () => decoder.decode(
        _singlePlan(taskDependencies: const <String>['missing']),
        requestId: 'request-2',
      ),
      throwsFormatException,
    );
  });

  test('rejects cyclic task graph before execution', () {
    final raw = jsonEncode(<String, Object>{
      'phases': <Object>[
        <String, Object>{
          'id': 'implementation',
          'title': 'Implementation',
          'description': 'Implement.',
          'dependsOn': <String>[],
        },
      ],
      'tasks': <Object>[
        <String, Object>{
          'id': 'a',
          'phaseId': 'implementation',
          'title': 'A',
          'description': 'Task A.',
          'dependsOn': <String>['b'],
          'affectedPaths': <String>['lib/a.dart'],
          'validationCriteria': <String>['A is valid.'],
        },
        <String, Object>{
          'id': 'b',
          'phaseId': 'implementation',
          'title': 'B',
          'description': 'Task B.',
          'dependsOn': <String>['a'],
          'affectedPaths': <String>['lib/b.dart'],
          'validationCriteria': <String>['B is valid.'],
        },
      ],
    });

    expect(
      () => decoder.decode(raw, requestId: 'request-3'),
      throwsFormatException,
    );
  });

  test('rejects unsafe affected paths', () {
    expect(
      () => decoder.decode(
        _singlePlan(affectedPaths: const <String>['../secret.txt']),
        requestId: 'request-4',
      ),
      throwsFormatException,
    );
    expect(
      () => decoder.decode(
        _singlePlan(affectedPaths: const <String>['C:/secret.txt']),
        requestId: 'request-4b',
      ),
      throwsFormatException,
    );
  });

  test('accepts fenced JSON but still validates the graph', () {
    final fenced = '~~~json\n${_singlePlan()}\n~~~'
        .replaceAll('~', String.fromCharCode(96));
    final plan = decoder.decode(fenced, requestId: 'request-5');
    expect(plan.tasks, hasLength(1));
  });

  test('accepts complete project JSON wrapped in model commentary', () {
    final raw = 'Here is the requested plan:\n${_singlePlan()}\nDone.';
    final plan = decoder.decode(raw, requestId: 'request-5b');

    expect(plan.tasks, hasLength(1));
    expect(plan.phases, hasLength(1));
  });

  test('recovers a complete project object inside a truncated outer wrapper', () {
    final raw = 'prefix {"plan": ${_singlePlan()}';
    final plan = decoder.decode(raw, requestId: 'request-5bb');

    expect(plan.tasks, hasLength(1));
    expect(plan.phases, hasLength(1));
  });

  test('keeps valid non-object JSON fail-closed', () {
    final wrapped = jsonEncode(<Object>[jsonDecode(_singlePlan())]);

    expect(
      () => decoder.decode(wrapped, requestId: 'request-5c'),
      throwsFormatException,
    );
  });

  test('planner preserves explicit offline mode to Architect inference', () async {
    final provider = _ScriptedProvider(<String>[_singlePlan()]);
    final planner = _planner(provider);

    final plan = await planner.plan(
      request: const WorkshopRequest(
        id: 'offline-request',
        title: 'Offline app',
        instruction: 'Create a small offline counter.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
      isOffline: true,
    );

    expect(plan.tasks, hasLength(1));
    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.isOffline, isTrue);
    expect(
      provider.requests.single.sessionId,
      'workshop:offline-request:project-plan',
    );
  });


  test('create planner tells Architect to declare every task source path',
      () async {
    final provider = _ScriptedProvider(<String>[_singlePlan()]);
    final planner = _planner(provider);

    await planner.plan(
      request: const WorkshopRequest(
        id: 'create-scope-contract',
        title: 'Manga Kids',
        instruction: 'Create a Flutter drawing app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
    );

    expect(
      provider.requests.single.prompt,
      contains('each task affectedPaths must list every source file'),
    );
    expect(
      provider.requests.single.prompt,
      contains('include that exact repository path in that task affectedPaths'),
    );
  });

  test('create planner deterministically adds lib/main.dart to root task',
      () async {
    final provider = _ScriptedProvider(<String>[
      _singlePlan(affectedPaths: const <String>['lib/app.dart']),
    ]);
    final planner = _planner(provider);

    final plan = await planner.plan(
      request: const WorkshopRequest(
        id: 'create-entrypoint-request',
        title: 'Contatore Test',
        instruction: 'Create a Flutter counter app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
    );

    expect(plan.tasks, hasLength(1));
    expect(
      plan.tasks.single.affectedPaths,
      <String>['lib/main.dart', 'lib/app.dart'],
    );
  });


  test('planner retries one transient timeout before project planning fails',
      () async {
    final provider = _ScriptedProvider(
      <String>['', _singlePlan()],
      terminalStates: const <InferenceTerminalState>[
        InferenceTerminalState.timeout,
        InferenceTerminalState.success,
      ],
    );
    final planner = _planner(provider);

    final plan = await planner.plan(
      request: const WorkshopRequest(
        id: 'timeout-retry-request',
        title: 'Contatore Test',
        instruction: 'Create the requested app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
    );

    expect(plan.tasks, hasLength(1));
    expect(provider.requests, hasLength(2));
    expect(provider.requests.last.sessionId, contains('retry-1'));
  });

  test('planner does not retry an owner-cancelled inference', () async {
    final provider = _ScriptedProvider(
      const <String>[''],
      terminalStates: const <InferenceTerminalState>[
        InferenceTerminalState.cancelled,
      ],
    );
    final planner = _planner(provider);

    await expectLater(
      planner.plan(
        request: const WorkshopRequest(
          id: 'cancelled-plan-request',
          title: 'Cancelled plan',
          instruction: 'Create the requested app.',
          source: WorkshopRequestSource.workshop,
          operation: WorkshopOperation.create,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('terminal=cancelled'),
        ),
      ),
    );

    expect(provider.requests, hasLength(1));
  });

  test('planner accepts wrapped Architect JSON without spending retry', () async {
    final provider = _ScriptedProvider(<String>[
      'Plan follows:\n${_singlePlan()}\nEnd of plan.',
    ]);
    final planner = _planner(provider);

    final plan = await planner.plan(
      request: const WorkshopRequest(
        id: 'wrapped-plan-request',
        title: 'Wrapped plan',
        instruction: 'Create the requested app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
    );

    expect(plan.tasks, hasLength(1));
    expect(provider.requests, hasLength(1));
  });

  test('planner retries one malformed Architect response', () async {
    final provider = _ScriptedProvider(<String>[
      'not-json',
      _singlePlan(),
    ]);
    final planner = _planner(provider);

    final plan = await planner.plan(
      request: const WorkshopRequest(
        id: 'retry-request',
        title: 'Retry app',
        instruction: 'Create the requested app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
    );

    expect(plan.tasks, hasLength(1));
    expect(provider.requests, hasLength(2));
    expect(provider.requests.last.sessionId, contains('retry-1'));
    expect(
      provider.requests.first.prompt,
      isNot(contains('retry mode: prefer exactly 1 phase and 1 task')),
    );
    expect(
      provider.requests.last.prompt,
      contains('retry mode: prefer exactly 1 phase and 1 task'),
    );
    expect(
      provider.requests.last.prompt,
      contains('output the JSON object only: no preface, suffix'),
    );
  });

  test('invalid planning output fails before WorkshopEngine project mutation',
      () async {
    final provider = _ScriptedProvider(<String>['bad', 'still-bad']);
    final engine = WorkshopEngine();
    final controller = WorkshopDashboardController(
      engine: engine,
      projectPlanner: _planner(provider),
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.startPlannedProduction(
        title: 'Unsafe plan',
        instruction: 'Create an app.',
      ),
      throwsFormatException,
    );

    expect(engine.plans, isEmpty);
    expect(engine.requests, isEmpty);
    expect(controller.state.hasProject, isFalse);
  });
}

WorkshopDynamicProjectPlanner _planner(_ScriptedProvider provider) {
  final gateways = <AppAiRole, WorkshopInferenceGateway>{
    for (final role in WorkshopRoleInferenceRouter.workshopRoles)
      role: WorkshopInferenceGateway(provider: provider),
  };

  return WorkshopDynamicProjectPlanner(
    inference: WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(gateways: gateways),
      ),
    ),
  );
}

final class _ScriptedProvider implements RuntimeInferenceProvider {
  _ScriptedProvider(
    this.outputs, {
    List<InferenceTerminalState> terminalStates =
        const <InferenceTerminalState>[],
  }) : terminalStates = List<InferenceTerminalState>.unmodifiable(
          terminalStates,
        );

  final List<String> outputs;
  final List<InferenceTerminalState> terminalStates;
  final List<InferenceRequest> requests = <InferenceRequest>[];
  int _index = 0;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    requests.add(request);
    if (_index >= outputs.length) {
      throw StateError('No scripted planner output remains.');
    }
    final index = _index++;
    final text = outputs[index];
    final terminalState = index < terminalStates.length
        ? terminalStates[index]
        : InferenceTerminalState.success;

    if (terminalState != InferenceTerminalState.success) {
      return Stream<InferenceResponse>.value(
        InferenceResponse.error(
          'scripted planner terminal state',
          state: terminalState,
        ),
      );
    }

    return Stream<InferenceResponse>.fromIterable(
      <InferenceResponse>[
        InferenceResponse(text: text, timestamp: 1),
        const InferenceResponse(
          text: '',
          timestamp: 2,
          isFinal: true,
          terminalState: InferenceTerminalState.success,
        ),
      ],
    );
  }
}

String _singlePlan({
  List<String> taskDependencies = const <String>[],
  List<String> affectedPaths = const <String>['lib/app.dart'],
}) {
  return jsonEncode(<String, Object>{
    'phases': <Object>[
      <String, Object>{
        'id': 'implementation',
        'title': 'Implementation',
        'description': 'Implement the request.',
        'dependsOn': <String>[],
      },
    ],
    'tasks': <Object>[
      <String, Object>{
        'id': 'implement',
        'phaseId': 'implementation',
        'title': 'Implement',
        'description': 'Implement one bounded increment.',
        'dependsOn': taskDependencies,
        'affectedPaths': affectedPaths,
        'validationCriteria': <String>['Requested behavior works.'],
      },
    ],
  });
}
