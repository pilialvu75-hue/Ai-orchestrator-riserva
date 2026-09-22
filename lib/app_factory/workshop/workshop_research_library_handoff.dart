import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission_service.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

/// Fail-closed handoff from a validated Researcher evolution candidate to the
/// existing Cantiere -> Module Library intake service.
///
/// This boundary never applies the candidate to the real workspace and never
/// writes stable_library/**. It only packages candidate_workspace/** additions
/// and modifications after Engineer -> Reviewer -> validation succeeded.
/// The existing Library submission gate remains authoritative for license,
/// security, vulnerability, Lego-contract and payload-integrity evidence.
final class WorkshopResearchLibraryHandoff {
  const WorkshopResearchLibraryHandoff({required this.submissionService});

  final WorkshopLibrarySubmissionService submissionService;

  Future<WorkshopLibrarySubmissionResult> submitValidatedCandidate({
    required WorkshopTaskContract task,
    required WorkshopTaskInferenceResult result,
    required WorkshopLibraryCaptureEvidence evidence,
  }) async {
    final rejection = _preflightRejection(task: task, result: result, evidence: evidence);
    if (rejection != null) {
      return WorkshopLibrarySubmissionResult.reject(<String>[rejection]);
    }

    final files = <WorkshopLibraryIntakePayloadFile>[];
    for (final change in result.proposal.changes) {
      if (change.isDeletion) {
        return WorkshopLibrarySubmissionResult.reject(
          const <String>['research-candidate-deletion-not-publishable'],
        );
      }
      final path = change.path.trim();
      if (!_isCandidatePath(path)) {
        return WorkshopLibrarySubmissionResult.reject(
          const <String>['research-candidate-outside-isolated-scope'],
        );
      }
      final relative = path.substring('candidate_workspace/'.length);
      final content = change.afterContent;
      if (content == null) {
        return WorkshopLibrarySubmissionResult.reject(
          const <String>['research-candidate-missing-content'],
        );
      }
      files.add(WorkshopLibraryIntakePayloadFile(
        path: relative,
        bytes: List<int>.unmodifiable(content.codeUnits),
      ));
    }

    if (files.isEmpty) {
      return WorkshopLibrarySubmissionResult.reject(
        const <String>['research-candidate-empty'],
      );
    }

    return submissionService.submit(evidence: evidence, files: files);
  }

  String? _preflightRejection({
    required WorkshopTaskContract task,
    required WorkshopTaskInferenceResult result,
    required WorkshopLibraryCaptureEvidence evidence,
  }) {
    if (!task.tags.contains('researcher-v2') ||
        !task.tags.contains('module-evolution') ||
        task.metadata['mutationPolicy'] != 'isolated_candidate_no_library_mutation' ||
        task.metadata['sourceCodeTransferred'] != false) {
      return 'unsafe-research-task-contract';
    }
    if (!task.fileScope.forbidden.contains('stable_library/**') ||
        task.fileScope.allowed.length != 1 ||
        task.fileScope.allowed.single != 'candidate_workspace/**') {
      return 'unsafe-research-task-scope';
    }
    if (!result.readyForApproval) return 'research-candidate-not-validated';
    if (evidence.sourceTaskId?.trim() != task.id) {
      return 'research-candidate-task-traceability-mismatch';
    }
    final capability = task.metadata['capabilityId']?.toString().trim();
    if (capability == null ||
        capability.isEmpty ||
        !evidence.capabilities.map((item) => item.trim()).contains(capability)) {
      return 'research-candidate-capability-mismatch';
    }
    return null;
  }

  bool _isCandidatePath(String path) =>
      path.startsWith('candidate_workspace/') &&
      path.length > 'candidate_workspace/'.length &&
      !path.contains('/../') &&
      !path.endsWith('/..');
}
