import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_preflight_inference_pipeline.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_decision_engine.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_reuse_library.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';

/// Result of a reuse-aware Workshop preflight.
///
/// [preflight] remains the canonical preflight result consumed by the existing
/// task lifecycle. [reuseDecision] explains whether verified local production
/// knowledge was strong enough to replace the first Orchestrator inference.
final class WorkshopReuseAwarePreflightResult {
  const WorkshopReuseAwarePreflightResult({
    required this.preflight,
    required this.reuseDecision,
  });

  final WorkshopPreflightInferenceResult preflight;
  final WorkshopReuseDecision reuseDecision;

  bool get reusedLocalKnowledge => reuseDecision.shouldReuse;
  WorkshopReusableAsset? get reusedAsset => reuseDecision.asset;
}

/// Reuse-first front door for the existing read-only Cantiere preflight.
///
/// Normal path (no strong reusable match):
///   Orchestrator AI -> Architect AI
///
/// Reuse path:
///   verified local catalog -> synthetic bounded analysis -> Architect AI
///
/// A strong verified match therefore removes one inference call while keeping
/// the Architect planning gate and all downstream review/validation/approval
/// boundaries intact. It never mutates the workspace and never treats reuse as
/// proof that a new project is already correct.
final class WorkshopReuseAwarePreflightPipeline {
  WorkshopReuseAwarePreflightPipeline({
    required WorkshopStageRoleInference inference,
    required WorkshopReuseLibrary library,
    WorkshopReuseDecisionEngine decisionEngine =
        const WorkshopReuseDecisionEngine(),
  })  : _inference = inference,
        _library = library,
        _decisionEngine = decisionEngine,
        _fallback = WorkshopPreflightInferencePipeline(inference: inference);

  final WorkshopStageRoleInference _inference;
  final WorkshopReuseLibrary _library;
  final WorkshopReuseDecisionEngine _decisionEngine;
  final WorkshopPreflightInferencePipeline _fallback;

  WorkshopReuseLibrary get library => _library;

  Future<WorkshopReuseAwarePreflightResult> run({
    required WorkshopRequest request,
    bool isOffline = true,
    List<String> requiredCapabilities = const <String>[],
    String? target,
    CancellationToken? cancellationToken,
  }) async {
    final decision = _decisionEngine.decide(
      library: _library,
      objective: '${request.title} ${request.instruction}',
      requiredCapabilities: requiredCapabilities,
      target: target,
    );

    if (!decision.shouldReuse || decision.asset == null) {
      final preflight = await _fallback.run(
        request: request,
        isOffline: isOffline,
        cancellationToken: cancellationToken,
      );
      return WorkshopReuseAwarePreflightResult(
        preflight: preflight,
        reuseDecision: decision,
      );
    }

    final asset = decision.asset!;
    final analysis = WorkshopInferenceResult(
      text: _localAnalysis(request: request, asset: asset),
      model: 'workshop-reuse-library',
      runtimeNotice: 'Verified local Workshop knowledge reused.',
      terminalState: InferenceTerminalState.success,
    );

    final architecture = await _inference.complete(
      stage: WorkshopStage.planning,
      prompt: _architecturePrompt(
        request: request,
        analysis: analysis.text,
        asset: asset,
      ),
      systemPrompt:
          'You are the Cantiere Architect. A previously verified local '
          'Workshop asset has been selected as a reusable reference. Adapt '
          'that proven knowledge to the current request with the smallest safe '
          'delta. Do not assume the old artifact is directly installable or '
          'correct for the new project. Do not write files, approve/apply '
          'changes, or use Assistant state.',
      sessionId: 'workshop:${request.id}:preflight:planning:reuse',
      isOffline: isOffline,
      cancellationToken: cancellationToken,
    );

    final preflight = WorkshopPreflightInferenceResult(
      analysis: analysis,
      architecture: architecture,
    );

    if (preflight.readyForImplementation) {
      _library.markUsed(asset.id);
    }

    return WorkshopReuseAwarePreflightResult(
      preflight: preflight,
      reuseDecision: decision,
    );
  }

  static String _localAnalysis({
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
        'This is reusable evidence, not an automatic approval. Preserve '
        'current-request constraints and validate every adapted change.',
      );

    return buffer.toString();
  }

  static String _architecturePrompt({
    required WorkshopRequest request,
    required String analysis,
    required WorkshopReusableAsset asset,
  }) {
    final buffer = StringBuffer()
      ..writeln('WORKSHOP REQUEST')
      ..writeln('id: ${request.id}')
      ..writeln('title: ${request.title}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('targetFiles: ${request.targetFiles.join(', ')}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln()
      ..writeln('VERIFIED REUSE ANALYSIS')
      ..writeln(analysis.trim())
      ..writeln()
      ..writeln('REUSE RULE')
      ..writeln(
        'Prefer adapting asset "${asset.name}" over regenerating equivalent '
        'work, but explicitly identify every required delta and validation '
        'step. Never bypass workspace review or approval.',
      );

    return buffer.toString();
  }
}
