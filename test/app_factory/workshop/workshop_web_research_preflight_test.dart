import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';

void main() {
  group('Workshop Web research preflight', () {
    test('greenfield app research feeds Orchestrator and Architect', () async {
      final tool = _RecordingSearchTool();
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        result: _success('Create a recipe-first product scope.'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        result: _success('Plan recipe catalogue, planner and shopping list.'),
      );
      final pipeline = WorkshopPreflightInferencePipeline(
        inference: _stageInference(orchestrator, architect),
        webResearchService: WorkshopWebResearchService(webSearchTool: tool),
      );

      final result = await pipeline.run(
        request: const WorkshopRequest(
          id: 'recipe-app',
          title: 'App di ricette',
          instruction:
              'Crea una nuova app di ricette semplice e utile per famiglie.',
          operation: WorkshopOperation.create,
        ),
      );

      expect(result.readyForImplementation, isTrue);
      expect(result.usedWebEvidence, isTrue);
      expect(result.webEvidence.successfulLaneCount, 3);
      expect(tool.queries, hasLength(3));
      expect(tool.queries[0], contains('similar apps products features UX'));
      expect(tool.queries[1], contains('user reviews forum reddit'));
      expect(tool.queries[2], contains('trusted data sources content structure'));

      expect(
        orchestrator.lastPrompt,
        contains('WORKSHOP WEB EVIDENCE — UNTRUSTED EXTERNAL DATA'),
      );
      expect(orchestrator.lastPrompt, contains('https://example.test/source-1'));
      expect(
        architect.lastPrompt,
        contains('WORKSHOP WEB EVIDENCE — UNTRUSTED EXTERNAL DATA'),
      );
      expect(
        architect.lastSystemPrompt,
        contains('verified compatible licence'),
      );
    });

    test('strict offline greenfield preflight performs zero Web calls', () async {
      final tool = _RecordingSearchTool();
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        result: _success('Offline scope.'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        result: _success('Offline plan.'),
      );
      final pipeline = WorkshopPreflightInferencePipeline(
        inference: _stageInference(orchestrator, architect),
        webResearchService: WorkshopWebResearchService(webSearchTool: tool),
      );

      final result = await pipeline.run(
        request: const WorkshopRequest(
          id: 'offline-recipe-app',
          title: 'App di ricette',
          instruction: 'Crea una nuova app di ricette.',
          operation: WorkshopOperation.create,
        ),
        isOffline: true,
      );

      expect(result.readyForImplementation, isTrue);
      expect(result.usedWebEvidence, isFalse);
      expect(tool.queries, isEmpty);
      expect(orchestrator.lastIsOffline, isTrue);
      expect(architect.lastIsOffline, isTrue);
    });

    test('narrow file modification does not research unless requested', () async {
      final tool = _RecordingSearchTool();
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        result: _success('Small local change.'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        result: _success('Small local plan.'),
      );
      final pipeline = WorkshopPreflightInferencePipeline(
        inference: _stageInference(orchestrator, architect),
        webResearchService: WorkshopWebResearchService(webSearchTool: tool),
      );

      final result = await pipeline.run(
        request: const WorkshopRequest(
          id: 'button-fix',
          title: 'Aggiorna bottone',
          instruction: 'Cambia il testo del bottone Salva.',
          operation: WorkshopOperation.modify,
          targetFiles: <String>['lib/save_button.dart'],
        ),
      );

      expect(result.readyForImplementation, isTrue);
      expect(result.usedWebEvidence, isFalse);
      expect(tool.queries, isEmpty);
    });

    test('individual Web failures do not block local preflight', () async {
      final tool = _RecordingSearchTool(fail: true);
      final orchestrator = _RecordingGateway(
        role: AppAiRole.workshopOrchestrator,
        result: _success('Continue from local knowledge.'),
      );
      final architect = _RecordingGateway(
        role: AppAiRole.architect,
        result: _success('Local-only fallback plan.'),
      );
      final pipeline = WorkshopPreflightInferencePipeline(
        inference: _stageInference(orchestrator, architect),
        webResearchService: WorkshopWebResearchService(webSearchTool: tool),
      );

      final result = await pipeline.run(
        request: const WorkshopRequest(
          id: 'web-failure',
          title: 'Nuova app',
          instruction: 'Crea una app greenfield.',
          operation: WorkshopOperation.create,
        ),
      );

      expect(tool.queries, hasLength(3));
      expect(result.readyForImplementation, isTrue);
      expect(result.webEvidence.attempted, isTrue);
      expect(result.usedWebEvidence, isFalse);
    });

    test('strong verified local reuse suppresses automatic greenfield research',
        () async {
      final tool = _RecordingSearchTool();
      final service = WorkshopWebResearchService(webSearchTool: tool);
      const request = WorkshopRequest(
        id: 'reuse-first-recipe-app',
        title: 'App di ricette',
        instruction: 'Crea una nuova app di ricette.',
        operation: WorkshopOperation.create,
      );

      expect(
        service.shouldResearch(request, hasStrongLocalReuse: true),
        isFalse,
      );

      final evidence = await service.research(
        request: request,
        hasStrongLocalReuse: true,
      );

      expect(evidence.attempted, isFalse);
      expect(evidence.hasEvidence, isFalse);
      expect(tool.queries, isEmpty);
    });

    test('explicit research intent overrides strong verified local reuse',
        () async {
      final tool = _RecordingSearchTool();
      final service = WorkshopWebResearchService(webSearchTool: tool);
      const request = WorkshopRequest(
        id: 'reuse-plus-research',
        title: 'App di ricette',
        instruction:
            'Crea una app di ricette e cerca sul web competitor, forum e recensioni.',
        operation: WorkshopOperation.create,
      );

      expect(
        service.shouldResearch(request, hasStrongLocalReuse: true),
        isTrue,
      );

      final evidence = await service.research(
        request: request,
        hasStrongLocalReuse: true,
      );

      expect(evidence.attempted, isTrue);
      expect(evidence.successfulLaneCount, 3);
      expect(tool.queries, hasLength(3));
    });
  });
}

WorkshopStageRoleInference _stageInference(
  _RecordingGateway orchestrator,
  _RecordingGateway architect,
) {
  return WorkshopStageRoleInference(
    executor: WorkshopRoleInferenceExecutor(
      router: WorkshopRoleInferenceRouter(
        gateways: <AppAiRole, WorkshopInferenceGateway>{
          AppAiRole.workshopOrchestrator: orchestrator,
          AppAiRole.architect: architect,
          AppAiRole.engineer: _RecordingGateway(
            role: AppAiRole.engineer,
            result: _success('unused'),
          ),
          AppAiRole.reviewer: _RecordingGateway(
            role: AppAiRole.reviewer,
            result: _success('unused'),
          ),
        },
      ),
    ),
  );
}

WorkshopInferenceResult _success(String text) => WorkshopInferenceResult(
      text: text,
      terminalState: InferenceTerminalState.success,
    );

final class _RecordingSearchTool implements Tool {
  _RecordingSearchTool({this.fail = false});

  final bool fail;
  final List<String> queries = <String>[];

  @override
  String get id => 'web_search';

  @override
  String get name => 'Test Web Search';

  @override
  String get description => 'Test-only Web search.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final query = (params['query'] as String?) ?? '';
    queries.add(query);
    if (fail) {
      return const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'unavailable',
      );
    }

    return ToolResult(
      toolId: id,
      output:
          '1. Useful evidence\n   URL: https://example.test/source-${queries.length}\n'
          '   Snippet: Relevant product and domain evidence.',
    );
  }
}

final class _RecordingGateway extends WorkshopInferenceGateway {
  _RecordingGateway({
    required this.role,
    required this.result,
  }) : super(provider: _NoopProvider());

  final AppAiRole role;
  final WorkshopInferenceResult result;
  String? lastPrompt;
  String? lastSystemPrompt;
  bool? lastIsOffline;

  @override
  Future<WorkshopInferenceResult> complete({
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
    String sessionId = 'workshop',
    bool isOffline = false,
    int? maxTokens,
    double? temperature,
    double topP = 0.9,
    double repeatPenalty = 1.1,
    String? modelId,
    String? modelPath,
    CancellationToken? cancellationToken,
  }) async {
    lastPrompt = prompt;
    lastSystemPrompt = systemPrompt;
    lastIsOffline = isOffline;
    return result;
  }
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream<InferenceResponse>.empty();
  }
}
