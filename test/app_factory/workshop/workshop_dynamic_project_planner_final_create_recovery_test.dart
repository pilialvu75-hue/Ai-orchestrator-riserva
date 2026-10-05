import 'dart:convert';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dynamic_project_planner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CREATE recovers after both planner outputs are truncated JSON', () async {
    RuntimeEventLog.instance.clear();
    final provider = _ScriptedProvider(<String>[
      '{"phases":[{"id":"implementation"',
      '{"phases":[{"id":"implementation","title":"Implementation"',
    ]);

    final plan = await _planner(provider).plan(
      request: const WorkshopRequest(
        id: 'manga-bigs-retry',
        title: 'Manga Bigs',
        instruction: 'Create the persisted Manga Bigs Flutter app.',
        source: WorkshopRequestSource.workshop,
        operation: WorkshopOperation.create,
      ),
      validationCriteria: const <String>[
        'The requested app remains complete and buildable.',
      ],
    );

    expect(provider.requests, hasLength(2));
    expect(plan.phases, hasLength(1));
    expect(plan.tasks, hasLength(1));
    expect(plan.tasks.single.affectedPaths, <String>['lib/main.dart']);
    expect(
      RuntimeEventLog.instance.entries.any(
        (entry) => entry.message.contains(
          '[WORKSHOP_PLANNER_RECOVERY] mode=deterministic_create_after_incomplete_retry',
        ),
      ),
      isTrue,
    );
  });

  test('plain non-JSON remains fail-closed after the normal retry', () async {
    final provider = _ScriptedProvider(<String>['not-json', 'still-not-json']);

    await expectLater(
      _planner(provider).plan(
        request: const WorkshopRequest(
          id: 'plain-invalid',
          title: 'Invalid plan',
          instruction: 'Create the requested app.',
          source: WorkshopRequestSource.workshop,
          operation: WorkshopOperation.create,
        ),
      ),
      throwsFormatException,
    );

    expect(provider.requests, hasLength(2));
  });

  test('syntactically valid unsafe retry never falls into CREATE recovery',
      () async {
    final provider = _ScriptedProvider(<String>[
      '{"phases":[',
      _singlePlan(affectedPaths: const <String>['lib/other.dart']),
    ]);

    await expectLater(
      _planner(provider).plan(
        request: const WorkshopRequest(
          id: 'unsafe-scope',
          title: 'Scoped create',
          instruction: 'Create only the approved entry point.',
          source: WorkshopRequestSource.workshop,
          operation: WorkshopOperation.create,
          targetFiles: <String>['lib/main.dart'],
        ),
      ),
      throwsFormatException,
    );

    expect(provider.requests, hasLength(2));
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
  _ScriptedProvider(this.outputs);

  final List<String> outputs;
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
    final text = outputs[_index++];
    return Stream<InferenceResponse>.fromIterable(<InferenceResponse>[
      InferenceResponse(text: text, timestamp: 1),
      const InferenceResponse(
        text: '',
        timestamp: 2,
        isFinal: true,
        terminalState: InferenceTerminalState.success,
      ),
    ]);
  }
}

String _singlePlan({
  List<String> affectedPaths = const <String>['lib/main.dart'],
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
        'dependsOn': <String>[],
        'affectedPaths': affectedPaths,
        'validationCriteria': <String>['Requested behavior works.'],
      },
    ],
  });
}
