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
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('WorkshopAirLabInferenceBridge', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('airlab-a5-');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test(
      'AIrLab staged output reaches normal Reviewer and validation without real writes',
      () async {
        final httpPaths = <String>[];
        final callOrder = <AppAiRole>[];
        final reviewer = _QueueGateway(
          role: AppAiRole.reviewer,
          callOrder: callOrder,
          results: <WorkshopInferenceResult>[
            _success(_approvedReviewJson),
            _success(_validValidationJson),
          ],
        );
        final gateway = _RecordingWorkspaceGateway(files: <String, String>{});
        final session = await _session(gateway);
        final bridge = WorkshopAirLabInferenceBridge(
          capability: createWorkshopAirLabIoCapability(
            baseUri: Uri.parse('http://127.0.0.1:8788'),
            httpClient: _airLabClient(httpPaths),
            enabled: true,
          ),
          inference: _stageInference(
            _gateways(reviewer: reviewer, callOrder: callOrder),
          ),
        );

        final result = await bridge.run(
          task: _task(),
          session: session,
          stagingRoot: '${temp.path}/staging',
          executionApprovalGranted: true,
          projectId: 'project-a5',
          target: 'android',
        );

        expect(result.readyForApproval, isTrue);
        expect(result.review.approved, isTrue);
        expect(result.validation?.valid, isTrue);
        expect(session.status, WorkspaceSessionStatus.validation);
        expect(session.isApplyApproved, isFalse);
        expect(
          session.workspace.read('.airlab/mock-result.txt'),
          'A5 deterministic result',
        );
        expect(callOrder, <AppAiRole>[
          AppAiRole.reviewer,
          AppAiRole.reviewer,
        ]);
        expect(reviewer.calls, 2);
        expect(
          httpPaths.where((path) => path == '/v1/tasks').length,
          1,
        );
        expect(gateway.writeCalls, 0);
        expect(gateway.deleteCalls, 0);
        expect(gateway.commitCalls, 0);
        expect(gateway.pushCalls, 0);
        expect(gateway.pullRequestCalls, 0);
      },
    );

    test('Reviewer rejection blocks before validation and never writes',
        () async {
      final callOrder = <AppAiRole>[];
      final reviewer = _QueueGateway(
        role: AppAiRole.reviewer,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[
          _success(_rejectedReviewJson),
          _success(_validValidationJson),
        ],
      );
      final gateway = _RecordingWorkspaceGateway(files: <String, String>{});
      final session = await _session(gateway);
      final bridge = WorkshopAirLabInferenceBridge(
        capability: createWorkshopAirLabIoCapability(
          baseUri: Uri.parse('http://127.0.0.1:8788'),
          httpClient: _airLabClient(<String>[]),
          enabled: true,
        ),
        inference: _stageInference(
          _gateways(reviewer: reviewer, callOrder: callOrder),
        ),
      );

      final result = await bridge.run(
        task: _task(),
        session: session,
        stagingRoot: '${temp.path}/staging',
        executionApprovalGranted: true,
      );

      expect(result.readyForApproval, isFalse);
      expect(result.review.approved, isFalse);
      expect(result.validation, isNull);
      expect(session.status, WorkspaceSessionStatus.blocked);
      expect(reviewer.calls, 1);
      expect(callOrder, <AppAiRole>[AppAiRole.reviewer]);
      expect(gateway.writeCalls, 0);
      expect(gateway.deleteCalls, 0);
    });

    test('Execution Guard approval remains mandatory before AIrLab task call',
        () async {
      final httpPaths = <String>[];
      final gateway = _RecordingWorkspaceGateway(files: <String, String>{});
      final session = await _session(gateway);
      final bridge = WorkshopAirLabInferenceBridge(
        capability: createWorkshopAirLabIoCapability(
          baseUri: Uri.parse('http://127.0.0.1:8788'),
          httpClient: _airLabClient(httpPaths),
          enabled: true,
        ),
        inference: _stageInference(
          _gateways(
            reviewer: _QueueGateway(
              role: AppAiRole.reviewer,
              callOrder: <AppAiRole>[],
              results: <WorkshopInferenceResult>[
                _success(_approvedReviewJson),
              ],
            ),
            callOrder: <AppAiRole>[],
          ),
        ),
      );

      await expectLater(
        bridge.run(
          task: _task(),
          session: session,
          stagingRoot: '${temp.path}/staging',
        ),
        throwsA(
          isA<WorkshopAirLabInferenceBridgeException>().having(
            (error) => error.code,
            'code',
            'airlab_not_promoted',
          ),
        ),
      );

      expect(httpPaths, <String>['/health']);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(gateway.writeCalls, 0);
    });

    test('pre-cancelled bridge performs no AIrLab or Reviewer work', () async {
      var httpCalls = 0;
      final reviewerCalls = <AppAiRole>[];
      final gateway = _RecordingWorkspaceGateway(files: <String, String>{});
      final session = await _session(gateway);
      final token = CancellationToken()..cancel();
      final bridge = WorkshopAirLabInferenceBridge(
        capability: createWorkshopAirLabIoCapability(
          baseUri: Uri.parse('http://127.0.0.1:8788'),
          httpClient: MockClient((request) async {
            httpCalls += 1;
            return http.Response('{}', 500);
          }),
          enabled: true,
        ),
        inference: _stageInference(
          _gateways(
            reviewer: _QueueGateway(
              role: AppAiRole.reviewer,
              callOrder: reviewerCalls,
              results: <WorkshopInferenceResult>[
                _success(_approvedReviewJson),
              ],
            ),
            callOrder: reviewerCalls,
          ),
        ),
      );

      await expectLater(
        bridge.run(
          task: _task(),
          session: session,
          stagingRoot: '${temp.path}/staging',
          executionApprovalGranted: true,
          cancellationToken: token,
        ),
        throwsA(
          isA<WorkshopAirLabInferenceBridgeException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );

      expect(httpCalls, 0);
      expect(reviewerCalls, isEmpty);
      expect(session.status, WorkspaceSessionStatus.ready);
      expect(gateway.writeCalls, 0);
    });
  });
}

MockClient _airLabClient(List<String> paths) {
  return MockClient((request) async {
    paths.add(request.url.path);
    if (request.url.path == '/health') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'status': 'ok',
          'service': 'airlab',
          'engine_id': 'mock-builder-a5',
        }),
        200,
      );
    }
    if (request.url.path == '/v1/capabilities') {
      return http.Response(jsonEncode(_capabilities()), 200);
    }
    if (request.url.path == '/v1/tasks') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'request_id': 'airlab-a5-request',
          'status': 'ok',
          'engine_id': 'mock-builder-a5',
          'plan': <String>['prepare deterministic staged output'],
          'operations': <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'create',
              'path': '.airlab/mock-result.txt',
              'content': 'A5 deterministic result',
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
      'engine_id': 'mock-builder-a5',
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

WorkshopTaskContract _task() {
  return WorkshopTaskContract(
    id: 'airlab-a5-task',
    title: 'A5 bridge task',
    objective: 'Create and validate the deterministic AIrLab mock result.',
    kind: WorkshopTaskKind.codeGeneration,
    mode: WorkshopTaskMode.local,
    preferredResource: WorkshopTaskResource.local,
    instructions: const <String>[
      'Use only the assigned Cantiere staging root.',
    ],
    acceptanceCriteria: const <WorkshopTaskAcceptanceCriterion>[
      WorkshopTaskAcceptanceCriterion(
        id: 'reviewed-result',
        description: 'The staged result passes Cantiere review and validation.',
      ),
    ],
    fileScope: const WorkshopTaskFileScope(
      allowed: <String>['.airlab/mock-result.txt'],
    ),
    metadata: const <String, dynamic>{
      'airlabTaskFamily': 'software',
      'airlabTaskKind': 'software.build',
    },
  );
}

Future<WorkspaceSession> _session(
  _RecordingWorkspaceGateway gateway,
) async {
  final session = WorkspaceSession(
    request: const WorkshopRequest(
      id: 'workspace-a5',
      title: 'A5 workspace',
      instruction: 'Review and validate AIrLab output safely.',
      targetFiles: <String>['.airlab/mock-result.txt'],
      constraints: <String>['No real workspace mutation before approval.'],
    ),
    gateway: gateway,
  );
  await session.initialize();
  return session;
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

WorkshopStageRoleInference _stageInference(
  Map<AppAiRole, _QueueGateway> gateways,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(gateways: gateways),
    ),
  );
}

Map<AppAiRole, _QueueGateway> _gateways({
  required _QueueGateway reviewer,
  required List<AppAiRole> callOrder,
}) {
  _QueueGateway idle(AppAiRole role) => _QueueGateway(
        role: role,
        callOrder: callOrder,
        results: <WorkshopInferenceResult>[_success('{}')],
      );

  return <AppAiRole, _QueueGateway>{
    AppAiRole.workshopOrchestrator: idle(AppAiRole.workshopOrchestrator),
    AppAiRole.architect: idle(AppAiRole.architect),
    AppAiRole.engineer: idle(AppAiRole.engineer),
    AppAiRole.reviewer: reviewer,
  };
}

const String _approvedReviewJson =
    '{"approved":true,"summary":"Review passed","findings":[],"warnings":[]}';

const String _rejectedReviewJson =
    '{"approved":false,"summary":"Review rejected","findings":["regression"],'
    '"warnings":[]}';

const String _validValidationJson =
    '{"valid":true,"summary":"Validation passed","checks":["consistent"],'
    '"warnings":[]}';

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
  int calls = 0;

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
    calls += 1;
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
