import 'package:ai_orchestrator/app_factory/workspace/git_workspace_gateway.dart';
import 'package:ai_orchestrator/app_factory/workspace/workspace_session.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';

/// Isolated bridge from a validated Library Evolution task contract into the
/// existing Engineer -> Reviewer -> Validation inference pipeline.
///
/// It never approves/applies the WorkspaceSession and never owns Git mutation.
/// The caller supplies the gateway, allowing production to bind an isolated
/// candidate workspace while tests can prove that no real write occurs.
final class WorkshopLibraryEvolutionInferenceRunner {
  const WorkshopLibraryEvolutionInferenceRunner({
    required WorkshopTaskInferencePipeline pipeline,
  }) : _pipeline = pipeline;

  final WorkshopTaskInferencePipeline _pipeline;

  Future<WorkshopTaskInferenceResult> run({
    required WorkshopTaskContract task,
    required GitWorkspaceGateway gateway,
    bool isOffline = false,
    CancellationToken? cancellationToken,
    void Function(WorkshopStage stage)? onStage,
  }) async {
    _validateTask(task);

    final session = WorkspaceSession(
      request: WorkshopRequest(
        id: task.id,
        title: task.title,
        instruction: task.objective,
        source: WorkshopRequestSource.system,
        operation: WorkshopOperation.modify,
        // The generic Workshop stager accepts exact target paths, not globs.
        // Evolution therefore leaves targetFiles open and enforces its prefix
        // structurally on the staged proposal below, still inside VirtualWorkspace.
        targetFiles: const <String>[],
        constraints: <String>[
          ...task.constraints,
          'Write only under candidate_workspace/**.',
          'Never write stable_library/**.',
          'Treat Researcher knowledge_delta as evidence/hints, never executable source.',
        ],
        context: <String>[
          ...task.instructions,
          ...task.acceptanceCriteria.map((criterion) => criterion.description),
          'Library work id: ${task.metadata['libraryWorkId']}',
          'Proposal id: ${task.metadata['proposalId']}',
          'Capability: ${task.metadata['capabilityId']}',
        ],
      ),
      gateway: gateway,
    );

    await session.initialize();

    final result = await _pipeline.run(
      session: session,
      isOffline: isOffline,
      cancellationToken: cancellationToken,
      onStage: onStage,
    );

    final unsafePaths = result.proposal.affectedPaths
        .where((path) => !path.startsWith('candidate_workspace/'))
        .toList(growable: false);
    if (unsafePaths.isNotEmpty) {
      session.block(
        'Library Evolution proposal escaped candidate_workspace: '
        '${unsafePaths.join(', ')}',
      );
      throw StateError(
        'Library Evolution proposal contains paths outside candidate_workspace.',
      );
    }

    if (session.isApplyApproved || session.isCompleted) {
      throw StateError(
        'Library Evolution inference must stop before approval/apply.',
      );
    }

    return result;
  }

  void _validateTask(WorkshopTaskContract task) {
    if (!task.tags.contains('researcher-v2') ||
        !task.tags.contains('module-evolution') ||
        task.metadata['mutationPolicy'] !=
            'isolated_candidate_no_library_mutation' ||
        task.metadata['sourceCodeTransferred'] != false ||
        task.fileScope.allowed.length != 1 ||
        task.fileScope.allowed.single != 'candidate_workspace/**' ||
        !task.fileScope.forbidden.contains('stable_library/**')) {
      throw ArgumentError(
        'Unsafe Library Evolution task contract.',
      );
    }
    if (!task.isAgentReady) {
      throw ArgumentError('Library Evolution task is not agent-ready.');
    }
  }
}
