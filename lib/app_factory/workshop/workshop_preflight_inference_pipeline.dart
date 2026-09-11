import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_decision_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';

/// Runs the read-only reasoning preflight for a Workshop request.
///
/// By default the Workshop Orchestrator analyses the request first and a
/// successful analysis is passed to the Architect for planning.
///
/// When a verified [reuseLibrary] is supplied, the pipeline evaluates it before
/// spending an Orchestrator inference. A sufficiently strong match becomes a
/// bounded local analysis and only the Architect is asked to plan the delta.
/// This preserves every downstream implementation/review/validation/approval
/// boundary while reducing repeated AI work.
final class WorkshopPreflightInferencePipeline {
  WorkshopPreflightInferencePipeline({
    required WorkshopStageRoleInference inference,
    WorkshopReuseLibrary? reuseLibrary,
    WorkshopReuseDecisionEngine reuseDecisionEngine =
        const WorkshopReuseDecisionEngine(),
  })  : _inference = inference,
        _reuseLibrary = reuseLibrary,
        _reuseDecisionEngine = reuseDecisionEngine;

  final WorkshopStageRoleInference _inference;
  final WorkshopReuseLibrary? _reuseLibrary;
  final WorkshopReuseDecisionEngine _reuseDecisionEngine;

  WorkshopReuseLibrary? get reuseLibrary => _reuseLibrary;

  Future<WorkshopPreflightInferenceResult> run({
    required WorkshopRequest request,
    bool isOffline = true,
    List<String> requiredCapabilities = const <String>[],
    String? target,
    CancellationToken? cancellationToken,
  }) async {
    final reuseDecision = _reuseDecision(
      request: request,
      requiredCapabilities: requiredCapabilities,
      target: target,
    );

    final WorkshopInferenceResult analysis;

    if (reuseDecision.shouldReuse && reuseDecision.asset != null) {
      analysis = WorkshopInferenceResult(
        text: _reuseAnalysis(
          request: request,
          asset: reuseDecision.asset!,
        ),
        model: 'workshop-reuse-library',
        runtimeNotice: 'Verified local Workshop knowledge reused.',
        terminalState: InferenceTerminalState.success,
      );
    } else {
      analysis = await _inference.complete(
        stage: WorkshopStage.analysis,
        prompt: _analysisPrompt(request),
        systemPrompt:
            'You are the Cantiere Orchestrator. Analyse only the supplied '
            'Workshop request, its explicit context and constraints. Do not '
            'use Assistant state and do not propose repository mutations.',
        sessionId: 'workshop:${request.id}:preflight:analysis',
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
    }

    if (!analysis.isSuccessful || !analysis.hasText) {
      return WorkshopPreflightInferenceResult(
        analysis: analysis,
        reuseDecision: reuseDecision,
      );
    }

    final architecture = await _inference.complete(
      stage: WorkshopStage.planning,
      prompt: _architecturePrompt(
        request: request,
        analysis: analysis.text,
        reusedAsset: reuseDecision.asset,
      ),
      systemPrompt: reuseDecision.shouldReuse
          ? 'You are the Cantiere Architect. A previously verified local '
              'Workshop asset has been selected as reusable evidence. Adapt '
              'the proven solution to the current request with the smallest '
              'safe delta. Do not assume the old artifact is directly valid '
              'for the new project. Do not write files, approve/apply changes, '
              'or use Assistant state.'
          : 'You are the Cantiere Architect. Produce a bounded implementation '
              'plan from the supplied Workshop request and Orchestrator '
              'analysis. Do not write files, approve/apply changes, or use '
              'Assistant state.',
      sessionId: reuseDecision.shouldReuse
          ? 'workshop:${request.id}:preflight:planning:reuse'
          : 'workshop:${request.id}:preflight:planning',
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    final result = WorkshopPreflightInferenceResult(
      analysis: analysis,
      architecture: architecture,
      reuseDecision: reuseDecision,
    );

    if (result.readyForImplementation && reuseDecision.asset != null) {
      _reuseLibrary?.markUsed(reuseDecision.asset!.id);
    }

    return result;
  }

  WorkshopReuseDecision _reuseDecision({
    required WorkshopRequest request,
    required List<String> requiredCapabilities,
    required String? target,
  }) {
    final library = _reuseLibrary;
    if (library == null || library.length == 0) {
      return WorkshopReuseDecision.generate('reuse-library-unavailable');
    }

    return _reuseDecisionEngine.decide(
      library: library,
      objective: '${request.title} ${request.instruction}',
      requiredCapabilities: requiredCapabilities,
      target: target,
    );
  }

  static String _analysisPrompt(WorkshopRequest request) {
    final buffer = StringBuffer()
      ..writeln('WORKSHOP REQUEST')
      ..writeln('id: ${request.id}')
      ..writeln('title: ${request.title}')
      ..writeln('operation: ${request.operation.name}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('projectPath: ${request.projectPath ?? ''}')
      ..writeln('targetFiles: ${request.targetFiles.join(', ')}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln('context: ${request.context.join(' | ')}')
      ..writeln()
      ..writeln(
        'Analyse scope, risks, dependencies and acceptance criteria. '
        'Return reasoning for the Architect; do not modify anything.',
      );

    return buffer.toString();
  }

  static String _reuseAnalysis({
    required WorkshopRequest request,
    required WorkshopReusableAsset asset,
  }) {
    final buffer = StringBuffer()
      ..writeln('VERIFIED LOCAL REUSE CANDIDATE')
      ..writeln('assetId: ${asset.id}')
      ..writeln('name: ${asset.name}')
      ..writeln('kind: ${asset.kind.name}')
      ..writeln('origin: ${asset.origin.name}')
      ..writeln('validationScore: ${asset.validationScore}')
      ..writeln('target: ${asset.target ?? ''}')
      ..writeln('capabilities: ${asset.capabilities.join(', ')}')
      ..writeln('tags: ${asset.tags.join(', ')}')
      ..writeln('entryPaths: ${asset.entryPaths.join(', ')}')
      ..writeln('sourceProjectId: ${asset.sourceProjectId ?? ''}')
      ..writeln('sourceTaskId: ${asset.sourceTaskId ?? ''}')
      ..writeln('artifactPath: ${asset.artifactPath ?? ''}')
      ..writeln('description: ${asset.description}')
      ..writeln()
      ..writeln('CURRENT REQUEST')
      ..writeln('id: ${request.id}')
      ..writeln('title: ${request.title}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln()
      ..writeln(
        'This asset is verified reusable evidence, not automatic approval. '
        'Preserve current-request constraints and validate every adapted '
        'change.',
      );

    return buffer.toString();
  }

  static String _architecturePrompt({
    required WorkshopRequest request,
    required String analysis,
    WorkshopReusableAsset? reusedAsset,
  }) {
    final buffer = StringBuffer()
      ..writeln('WORKSHOP REQUEST')
      ..writeln('id: ${request.id}')
      ..writeln('title: ${request.title}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('targetFiles: ${request.targetFiles.join(', ')}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln()
      ..writeln(
        reusedAsset == null ? 'ORCHESTRATOR ANALYSIS' : 'VERIFIED REUSE ANALYSIS',
      )
      ..writeln(analysis.trim())
      ..writeln();

    if (reusedAsset != null) {
      buffer
        ..writeln('REUSE RULE')
        ..writeln(
          'Prefer adapting "${reusedAsset.name}" over regenerating equivalent '
          'work. Explicitly identify required deltas and validation steps.',
        )
        ..writeln();
    }

    buffer.writeln(
      'Produce the smallest safe implementation plan for the Engineer, '
      'including files/areas to inspect and validation criteria. '
      'Do not modify anything.',
    );

    return buffer.toString();
  }
}

final class WorkshopPreflightInferenceResult {
  const WorkshopPreflightInferenceResult({
    required this.analysis,
    this.architecture,
    this.reuseDecision,
  });

  final WorkshopInferenceResult analysis;
  final WorkshopInferenceResult? architecture;
  final WorkshopReuseDecision? reuseDecision;

  bool get analysisReady => analysis.isSuccessful && analysis.hasText;

  bool get architectureReady =>
      architecture?.isSuccessful == true && architecture?.hasText == true;

  bool get readyForImplementation => analysisReady && architectureReady;

  bool get reusedLocalKnowledge => reuseDecision?.shouldReuse == true;

  WorkshopReusableAsset? get reusedAsset => reuseDecision?.asset;
}
