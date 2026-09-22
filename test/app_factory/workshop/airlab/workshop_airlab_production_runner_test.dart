import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_capability_io.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_inference_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/airlab/workshop_airlab_production_runner.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_project_plan.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopAirLabProductionExecutionRunner', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('airlab-a6-');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('disabled selector returns the exact historical runner instance', () async {
      final handle = await _handle();
      final historical = _HistoricalRunner(handle);

      final selected = WorkshopAirLabProductionRunnerSelector.select(
        enabled: false,
        historicalRunner: historical,
      );

      expect(identical(selected, historical), isTrue);
      expect(selected, isA<WorkshopProductionSemanticResumeRunner>());
    });

    test(
      'production controller consumes explicit AIrLab runner without historical inference or real writes',
      () async {
        final payloads = <Map<String, dynamic>>[];
        final reviewerCalls = <AppAiRole>[];
        final realGateway = _RecordingWorkspaceGateway(files: <String, String>{});
        final handle = await _handle(
          gateway: realGateway,
          affectedPaths: const <String>['.airlab/mock-result.txt'],
          targetFiles: const <String>['.airlab/mock-result.txt'],
        );
        final historical = _HistoricalRunner(handle);

        final bridge = WorkshopAirLabInferenceBridge(
          capability: createWorkshopAirLabIoCapability(
            baseUri: Uri.parse('http://127.0.0.1:8788'),
            httpClient: _airLabClient(payloads: payloads),
            enabled: true,
          ),
          inference: _stageInference(reviewerCalls),
        );

        final selected = WorkshopAirLabProductionRunnerSelector.select(
          enabled: true,
          historicalRunner: historical,
          bridge: bridge,
          stagingRootResolver: (_) => '${temp.path}/staging',
          targetResolver: (_) => 'android',
          approvalResolver: (_) => true,
        );

        expect(identical(selected, historical), isFalse);
        expect(selected, isNot(isA<WorkshopProductionSemanticResumeRunner>()));

        final controller = WorkshopProductionExecutionController(
          runner: selected,
        );

        final result = await controller.start();

        expect(result.readyForApproval, isTrue);
        expect(result.review.approved, isTrue);
        expect(result.validation?.valid, isTrue);
        expect(controller.state.status,
            WorkshopProductionExecutionStatus.succeeded);
        expect(handle.session.status, WorkspaceSessionStatus.validation);
        expect(handle.session.isApplyApproved, isFalse);
        expect(historical.runCount, 0);
        expect(reviewerCalls, <AppAiRole>[
          AppAiRole.reviewer,
          AppAiRole.reviewer,
        ]);
        expect(payloads, hasLength(1));
        expect(payloads.single['target'], 'android');
        expect(payloads.single['task_family'], 'software');
        expect(payloads.single['task_kind'], 'software.build');
        expect(
          handle.session.workspace.read('.airlab/mock-result.txt'),
          'A6 deterministic result',
        );

        // Production controller reached the ordinary approval-ready state,
        // but the backing workspace is still untouched.
        expect(realGateway.files, isEmpty);
        expect(realGateway.writeCalls, 0);
        expect(realGateway.deleteCalls, 0);
        expect(realGateway.commitCalls, 0);
        expect(realGateway.pushCalls, 0);
        expect(realGateway.pullRequestCalls, 0);

        controller.dispose();
      },
    );

    test('mutating production task without explicit writable scope fails before HTTP',
        () async {
      var httpCalls = 0;
      final handle = await _handle(
        affectedPaths: const <String>[],
        targetFiles: const <String>[],
      );
      final historical = _HistoricalRunner(handle);
      final selected = WorkshopAirLabProductionRunnerSelector.select(
        enabled: true,
        historicalRunner: historical,
        bridge: WorkshopAirLabInferenceBridge(
          capability: createWorkshopAirLabIoCapability(
            baseUri: Uri.parse('http://127.0.0.1:8788'),
            httpClient: MockClient((request) async {
              httpCalls += 1;
              return http.Response('{}', 500);
            }),
            enabled: true,
          ),
          inference: _stageInference(<AppAiRole>[]),
        ),
        stagingRootResolver: (_) => '${temp.path}/staging',
        targetResolver: (_) => 'android',
        approvalResolver: (_) => true,
      );

      final controller = WorkshopProductionExecutionController(
        runner: selected,
      );

      await expectLater(
        controller.start(),
        throwsA(
          isA<WorkshopAirLabProductionMappingException>().having(
            (error) => error.code,
            'code',
            'writable_scope_missing',
          ),
        ),
      );

      expect(controller.state.status, WorkshopProductionExecutionStatus.failed);
      expect(httpCalls, 0);
      expect(historical.runCount, 0);
      controller.dispose();
    });

    test('unsupported production domain fails before HTTP', () async {
      var httpCalls = 0;
      final handle = await _handle(
        domain: WorkshopProjectDomain.mechanical,
        affectedPaths: const <String>['part.step'],
        targetFiles: const <String>['part.step'],
      );
      final historical = _HistoricalRunner(handle);
      final selected = WorkshopAirLabProductionRunnerSelector.select(
        enabled: true,
        historicalRunner: historical,
        bridge: WorkshopAirLabInferenceBridge(
          capability: createWorkshopAirLabIoCapability(
            baseUri: Uri.parse('http://127.0.0.1:8788'),
            httpClient: MockClient((request) async {
              httpCalls += 1;
              return http.Response('{}', 500);
            }),
            enabled: true,
          ),
          inference: _stageInference(<AppAiRole>[]),
        ),
        stagingRootResolver: (_) => '${temp.path}/staging',
        targetResolver: (_) => 'android',
        approvalResolver: (_) => true,
      );

      final controller = WorkshopProductionExecutionController(
        runner: selected,
      );

      await expectLater(
        controller.start(),
        throwsA(
          isA<WorkshopAirLabProductionMappingException>().having(
            (error) => error.code,
            'code',
            'unsupported_project_domain',
          ),
        ),
      );

      expect(httpCalls, 0);
      expect(historical.runCount, 0);
      controller.dispose();
    });

    test('invalid absolute production scope fails before HTTP', () async {
      var httpCalls = 0;
      final handle = await _handle(
        affectedPaths: const <String>['/tmp/escape.dart'],
      );
      final historical = _HistoricalRunner(handle);
      final selected = WorkshopAirLabProductionRunnerSelector.select(
        enabled: true,
        historicalRunner: historical,
        bridge: WorkshopAirLabInferenceBridge(
          capability: createWorkshopAirLabIoCapability(
            baseUri: Uri.parse('http://127.0.0.1:8788'),
            httpClient: MockClient((request) async {
              httpCalls += 1;
              return http.Response('{}', 500);
            }),
            enabled: true,
          ),
          inference: _stageInference(<AppAiRole>[]),
        ),
        stagingRootResolver: (_) => '${temp.path}/staging',
        targetResolver: (_) => 'android',
        approvalResolver: (_) => true,
      );

      final controller = WorkshopProductionExecutionController(
        runner: selected,
      );

      await expectLater(
        controller.start(),
        throwsA(
          isA<WorkshopAirLabProductionMappingException>().having(
            (error) => error.code,
            'code',
            'absolute_scope_path',
          ),
        ),
      );

      expect(httpCalls, 0);
      expect(historical.runCount, 0);
      controller.dispose();
    });

    test('enabled selector requires all explicit A6 configuration', () async {
      final historical = _HistoricalRunner(await _handle());

      expect(
        () => WorkshopAirLabProductionRunnerSelector.select(
          enabled: true,
          historicalRunner: historical,
        ),
        throwsA(
          isA<WorkshopAirLabProductionMappingException>().having(
            (error) => error.code,
            'code',
            'airlab_production_configuration_incomplete',
          ),
        ),
      );
    });
  });
}

MockClient _airLabClient({
  required List<Map<String, dynamic>> payloads,
}) {
  return MockClient((request) async {
    if (request.url.path == '/health') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'status': 'ok',
          'service': 'airlab',
          'engine_id': 'mock-builder-a6',
        }),
        200,
      );
    }
    if (request.url.path == '/v1/capabilities') {
      return http.Response(jsonEncode(_capabilities()), 200);
    }
    if (request.url.path == '/v1/tasks') {
      payloads.add(
        Map<String, dynamic>.from(
          jsonDecode(request.body) as Map,
        ),
      );
      return http.Response(
        jsonEncode(<String, dynamic>{
          'request_id': 'airlab-a6-request',
          'status': 'ok',
          'engine_id': 'mock-builder-a6',
          'plan': <String>['prepare deterministic staged output'],
          'operations': <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'create',
              'path': '.airlab/mock-result.txt',
              'content': 'A6 deterministic result',
            },
          ],
          'artifacts': <Map<String, dynamic>>[],
          'metadata': <String, dynamic>{'mock': true},
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

Map<String, dynamic> _capabilities() => <String, dynamic>{
      'service': 'airlab',
      'engine_id': 'mock-builder-a6',
      'engine_kind': 'mock',
      'hardware_required': false,
      'supports_streaming': false,
      'supports_tools': false,
      'max_context_tokens': null,
      'task_families': <String>[
        'software',
        'web',
        'cad',
        'manufacturing',
      ],
      'input_kinds': <String>[
        'text',
        'image',
        'drawing',
        'file',
        'measurement',
        'project',
      ],
      'artifact_formats': <String>[
        'airlab',
        'step',
        'scad',
        'dxf',
        'svg',
        '3mf',
        'stl',
        'gcode',
      ],
    };

Future<WorkshopProductionTaskHandle> _handle({
  _RecordingWorkspaceGateway? gateway,
  WorkshopProjectDomain domain = WorkshopProjectDomain.software,
  List<String> affectedPaths = const <String>['.airlab/mock-result.txt'],
  List<String> targetFiles = const <String>[],
}) async {
  final realGateway =
      gateway ?? _RecordingWorkspaceGateway(files: <String, String>{});
  final session = WorkspaceSession(
    request: WorkshopRequest(
      id: 'request-a6',
      title: 'A6 production request',
      instruction: 'Create the deterministic production output.',
      operation: WorkshopOperation.create,
      targetFiles: targetFiles,
      constraints: const <String>[
        'Do not mutate the real workspace before explicit approval.',
      ],
    ),
    gateway: realGateway,
  );
  await session.initialize();

  final task = WorkshopProjectTask(
    id: 'task-a6',
    title: 'Implement deterministic output',
    description: 'Create the requested deterministic output safely.',
    phaseId: 'phase-a6',
    priority: WorkshopProjectPriority.normal,
    affectedPaths: affectedPaths,
    validationCriteria: const <String>[
      'The staged output is reviewed and validated.',
    ],
  );

  final plan = WorkshopProjectPlan(
    id: 'project-a6',
    title: 'A6 production project',
    goal: 'Exercise AIrLab through the production runner boundary.',
    domain: domain,
    status: WorkshopProjectStatus.inProgress,
    requirements: const <String>[
      'Use the guarded Cantiere lifecycle.',
    ],
    constraints: const <String>[
      'No direct repository writes from AIrLab.',
    ],
    technologies: const <String>['flutter'],
    deliverables: const <String>['validated staged output'],
    validationCriteria: const <String>[
      'Reviewer and validation must pass.',
    ],
    tasks: <WorkshopProjectTask>[task],
  );

  return WorkshopProductionTaskHandle(
    plan: plan,
    taskId: task.id,
    session: session,
  );
}

WorkshopStageRoleInference _stageInference(List<AppAiRole> calls) {
  final reviewer = _QueueGateway(
    role: AppAiRole.reviewer,
    callOrder: calls,
    results: <WorkshopInferenceResult>[
      _success(_approvedReviewJson),
      _success(_validValidationJson),
    ],
  );

  _QueueGateway idle(AppAiRole role) => _QueueGateway(
        role: role,
        callOrder: calls,
        results: <WorkshopInferenceResult>[_success('{}')],
      );

  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(
        gateways: <AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator:
              idle(AppAiRole.workshopOrchestrator),
          AppAiRole.architect: idle(AppAiRole.architect),
          AppAiRole.engineer: idle(AppAiRole.engineer),
          AppAiRole.reviewer: reviewer,
        },
      ),
    ),
  );
}

const String _approvedReviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';

const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _HistoricalRunner
    implements
        WorkshopProductionExecutionRunner,
        WorkshopProductionSemanticResumeRunner {
  _HistoricalRunner(this.handle);

  final WorkshopProductionTaskHandle handle;
  int runCount = 0;

  @override
  WorkshopProductionTaskHandle preparedHandle() => handle;

  @override
  Future<WorkshopTaskInferenceResult> runPrepared({
    required WorkshopProductionTaskHandle handle,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    runCount += 1;
    throw StateError('Historical runner must not execute in AIrLab A6 tests.');
  }

  @override
  Future<WorkshopTaskInferenceResult> runPreparedWithResumeContext({
    required WorkshopProductionTaskHandle handle,
    required dynamic resumeContext,
    required CancellationToken cancellationToken,
    required bool isOffline,
  }) {
    runCount += 1;
    throw StateError(
      'Historical semantic runner must not execute in AIrLab A6 tests.',
    );
  }
}

final class _QueueGateway extends WorkshopInferenceGateway {
  _QueueGateway({
    required this.role,
    required this.callOrder,
    required List<WorkshopInferenceResult> results,
  })  : _results = List<WorkshopInferenceResult>.from(results),
        super(provider: _NoopProvider());

  final AppAiRole role;
  final List<AppAiRole> callOrder;
  final List<WorkshopInferenceResult> _results;

  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = true,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    callOrder.add(role);
    if (_results.isEmpty) {
      throw StateError('No queued result for ${role.id}.');
    }
    return _results.removeAt(0);
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}

final class _RecordingWorkspaceGateway implements GitWorkspaceGateway {
  _RecordingWorkspaceGateway({required Map<String, String> files})
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
  Future<void> writeFile({
    required String path,
    required String content,
  }) async {
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
