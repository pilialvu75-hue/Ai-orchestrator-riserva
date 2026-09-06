import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Runs the read-only reasoning preflight for a Workshop request.
///
/// The Workshop Orchestrator analyses the request first. Only a successful
/// analysis is then passed to the Architect for planning. This pipeline does
/// not create or mutate a workspace, approve/apply changes, or consult any
/// Assistant configuration, model selection, memory or conversation state.
final class WorkshopPreflightInferencePipeline {
  const WorkshopPreflightInferencePipeline({
    required WorkshopStageRoleInference inference,
  }) : _inference = inference;

  final WorkshopStageRoleInference _inference;

  Future<WorkshopPreflightInferenceResult> run({
    required WorkshopRequest request,
    CancellationToken? cancellationToken,
  }) async {
    final analysis = await _inference.complete(
      stage: WorkshopStage.analysis,
      prompt: _analysisPrompt(request),
      systemPrompt:
          'You are the Cantiere Orchestrator. Analyse only the supplied '
          'Workshop request, its explicit context and constraints. Do not '
          'use Assistant state and do not propose repository mutations.',
      sessionId: 'workshop:${request.id}:preflight:analysis',
      cancellationToken: cancellationToken,
    );

    if (!analysis.isSuccessful || !analysis.hasText) {
      return WorkshopPreflightInferenceResult(
        analysis: analysis,
      );
    }

    final architecture = await _inference.complete(
      stage: WorkshopStage.planning,
      prompt: _architecturePrompt(
        request: request,
        analysis: analysis.text,
      ),
      systemPrompt:
          'You are the Cantiere Architect. Produce a bounded implementation '
          'plan from the supplied Workshop request and Orchestrator analysis. '
          'Do not write files, approve/apply changes, or use Assistant state.',
      sessionId: 'workshop:${request.id}:preflight:planning',
      cancellationToken: cancellationToken,
    );

    return WorkshopPreflightInferenceResult(
      analysis: analysis,
      architecture: architecture,
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

  static String _architecturePrompt({
    required WorkshopRequest request,
    required String analysis,
  }) {
    final buffer = StringBuffer()
      ..writeln('WORKSHOP REQUEST')
      ..writeln('id: ${request.id}')
      ..writeln('title: ${request.title}')
      ..writeln('instruction: ${request.instruction}')
      ..writeln('targetFiles: ${request.targetFiles.join(', ')}')
      ..writeln('constraints: ${request.constraints.join(' | ')}')
      ..writeln()
      ..writeln('ORCHESTRATOR ANALYSIS')
      ..writeln(analysis.trim())
      ..writeln()
      ..writeln(
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
  });

  final WorkshopInferenceResult analysis;
  final WorkshopInferenceResult? architecture;

  bool get analysisReady => analysis.isSuccessful && analysis.hasText;

  bool get architectureReady =>
      architecture?.isSuccessful == true && architecture?.hasText == true;

  bool get readyForImplementation => analysisReady && architectureReady;
}
