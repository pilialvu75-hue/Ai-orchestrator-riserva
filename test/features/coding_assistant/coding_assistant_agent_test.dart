import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/agents/agent_lifecycle.dart';
import 'package:ai_orchestrator/core/planner/planner_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/features/coding_assistant/coding_assistant_agent_impl.dart';
import 'package:ai_orchestrator/features/coding_assistant/in_memory_shared_context.dart';

const _validModel = AiModel(
  id: 'gemma_2b',
  displayName: 'Gemma 2B',
  fileName: 'gemma.gguf',
  downloadUrl: 'https://example.com/model.gguf',
  version: '1.0.0',
  sizeBytes: 123,
  description: 'Test model',
  isDownloaded: true,
  localPath: '/tmp/gemma.gguf',
  validationStatus: ModelValidationStatus.validatedOk,
);

class _FakeLocal extends LocalRuntimeProvider {
  _FakeLocal(this._response);
  final String _response;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  Future<LocalRuntimeState> ensureReadyForInference({
    required AiModel selectedModel,
    String source = 'inference',
  }) async {
    return const LocalRuntimeState(
      status: LocalRuntimeStatus.ready,
      message: 'ready',
    );
  }

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    yield InferenceResponse.finalChunk(
      text: _response,
      tokensGenerated: 1,
      model: 'fake',
    );
  }
}

CloudRuntimeProvider _noCloud() => CloudRuntimeProvider(
      sendQuery: (_, __) async => throw const ServerFailure('disabled'),
      supportedProviders: () => [],
      isProviderAvailable: (_) => false,
      providerDisplayName: ([_]) => '',
    );

InferenceService _buildInference(String fakeResponse) => InferenceService(
      loadSelectedModel: () async => _validModel,
      loadRuntimeMode: () async => AiRuntimeMode.local,
      runtimeProvider: _FakeLocal(fakeResponse),
      cloudRuntimeProvider: _noCloud(),
      sessionManager: RuntimeSessionManager(),
    );

CodingAssistantAgentImpl _buildAgent({String planResponse = '1. Only step'}) {
  final inference = _buildInference(planResponse);
  final planner = PlannerService(inferenceService: inference);
  return CodingAssistantAgentImpl(
    plannerService: planner,
    inferenceService: inference,
  );
}

void main() {
  group('CodingAssistantAgentImpl – identity', () {
    test('id is coding_assistant', () {
      expect(_buildAgent().id, 'coding_assistant');
    });

    test('name is non-empty', () {
      expect(_buildAgent().name, isNotEmpty);
    });

    test('strategyId is chain_of_thought', () {
      expect(_buildAgent().strategyId, 'chain_of_thought');
    });
  });

  group('CodingAssistantAgentImpl – lifecycle', () {
    test('starts in created state', () {
      final agent = _buildAgent();
      expect(agent.lifecycleState, AgentLifecycleState.created);
    });

    test('transitions to idle after initialize()', () async {
      final agent = _buildAgent();
      await agent.initialize();
      expect(agent.lifecycleState, AgentLifecycleState.idle);
    });

    test('transitions to active after activate()', () async {
      final agent = _buildAgent();
      await agent.initialize();
      await agent.activate();
      expect(agent.lifecycleState, AgentLifecycleState.active);
      expect(agent.isRunning, isTrue);
    });

    test('transitions to suspended after suspend()', () async {
      final agent = _buildAgent();
      await agent.initialize();
      await agent.activate();
      await agent.suspend();
      expect(agent.lifecycleState, AgentLifecycleState.suspended);
    });

    test('transitions to shutdown after shutdown()', () async {
      final agent = _buildAgent();
      await agent.shutdown();
      expect(agent.lifecycleState, AgentLifecycleState.shutdown);
    });
  });

  group('CodingAssistantAgentImpl – reason()', () {
    test('returns ReasoningResult with success=true on valid plan', () async {
      final agent = _buildAgent(planResponse: '1. Analyse\n2. Fix\n3. Verify');
      final context = InMemorySharedContext(sessionId: 'test-session');

      final result = await agent.reason('Fix the null pointer bug', context);

      expect(result.success, isTrue);
      expect(result.steps, isNotEmpty);
      expect(result.conclusion, isNotEmpty);
    });

    test('result problem matches input', () async {
      final agent = _buildAgent(planResponse: '1. Only step');
      final context = InMemorySharedContext(sessionId: 'test-session');

      final result = await agent.reason('My problem', context);

      expect(result.problem, 'My problem');
    });

    test('reasoning steps count matches plan steps (up to maxSteps)', () async {
      // LLM returns 3 steps; maxSteps defaults to 10 so all 3 run.
      final agent = _buildAgent(planResponse: '1. A\n2. B\n3. C');
      final context = InMemorySharedContext(sessionId: 'test-session');

      final result = await agent.reason('Do three things', context);

      expect(result.steps.length, 3);
    });

    test('respects maxSteps cap', () async {
      // LLM returns 5 steps but we cap at 2.
      final agent =
          _buildAgent(planResponse: '1. A\n2. B\n3. C\n4. D\n5. E');
      final context = InMemorySharedContext(sessionId: 'test-session');

      final result = await agent.reason('Do five things', context, maxSteps: 2);

      expect(result.steps.length, lessThanOrEqualTo(2));
    });
  });

  group('CodingAssistantAgentImpl – executeTask()', () {
    test('returns TaskExecutionResult with correct taskId', () async {
      final agent = _buildAgent(planResponse: '1. Do it');
      final context = InMemorySharedContext(sessionId: 'task-session');

      final result = await agent.executeTask('task-42', 'Fix bug', context);

      expect(result.taskId, 'task-42');
      expect(result.agentId, 'coding_assistant');
    });
  });

  group('InMemorySharedContext', () {
    test('stores and retrieves values', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      ctx.set('key', 'value');
      expect(ctx.get<String>('key'), 'value');
    });

    test('returns null for missing key', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      expect(ctx.get<String>('missing'), isNull);
    });

    test('remove deletes the key', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      ctx.set('x', 1);
      ctx.remove('x');
      expect(ctx.containsKey('x'), isFalse);
    });

    test('merge adds all entries from map', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      ctx.merge({'a': 1, 'b': 2});
      expect(ctx.get<int>('a'), 1);
      expect(ctx.get<int>('b'), 2);
    });

    test('clear removes all entries', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      ctx.set('k', 'v');
      ctx.clear();
      expect(ctx.snapshot, isEmpty);
    });

    test('snapshot is unmodifiable', () {
      final ctx = InMemorySharedContext(sessionId: 'ctx-test');
      ctx.set('k', 'v');
      expect(() => ctx.snapshot['new'] = 'x', throwsA(anything));
    });

    test('sessionId is correct', () {
      final ctx = InMemorySharedContext(sessionId: 'my-session');
      expect(ctx.sessionId, 'my-session');
    });
  });
}
