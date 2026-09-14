import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_transport.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';

final class WorkshopLibrarySubmissionResult {
  const WorkshopLibrarySubmissionResult._({
    required this.transmitted,
    required this.reasons,
    this.receipt,
  });

  final bool transmitted;
  final List<String> reasons;
  final WorkshopLibraryGitHubSubmissionReceipt? receipt;

  factory WorkshopLibrarySubmissionResult.success(
    WorkshopLibraryGitHubSubmissionReceipt receipt,
  ) => WorkshopLibrarySubmissionResult._(
        transmitted: true,
        reasons: const <String>[],
        receipt: receipt,
      );

  factory WorkshopLibrarySubmissionResult.reject(Iterable<String> reasons) =>
      WorkshopLibrarySubmissionResult._(
        transmitted: false,
        reasons: List<String>.unmodifiable(reasons),
      );
}

/// One fail-closed application service for the complete Cantiere -> Library
/// candidate path: evidence gate -> immutable payload bundle -> authenticated
/// Library pull request transport.
///
/// A successful build alone is intentionally insufficient. Callers must provide
/// [WorkshopLibraryCaptureEvidence] containing the license, security, validation,
/// vulnerability and Lego-contract evidence required by the existing gate.
final class WorkshopLibrarySubmissionService {
  const WorkshopLibrarySubmissionService({
    required this.submitBundle,
    this.gate = const WorkshopLibrarySubmissionGate(),
  });

  final Future<WorkshopLibraryGitHubSubmissionReceipt> Function(
    WorkshopLibraryIntakeBundle bundle,
  ) submitBundle;
  final WorkshopLibrarySubmissionGate gate;

  Future<WorkshopLibrarySubmissionResult> submit({
    required WorkshopLibraryCaptureEvidence evidence,
    required Iterable<WorkshopLibraryIntakePayloadFile> files,
  }) async {
    final payloadFiles = files.toList(growable: false);
    String computedSha;
    try {
      computedSha = WorkshopLibraryIntakeBundle.computePayloadSha256(payloadFiles);
    } catch (error) {
      return WorkshopLibrarySubmissionResult.reject(
        <String>['invalid-payload: ${error.runtimeType}'],
      );
    }

    if (evidence.payload.type != WorkshopLibraryPayloadType.archive) {
      return WorkshopLibrarySubmissionResult.reject(
        const <String>['payload-must-be-archive'],
      );
    }
    if (evidence.payload.sha256.trim().toLowerCase() != computedSha) {
      return WorkshopLibrarySubmissionResult.reject(
        const <String>['payload-sha256-mismatch'],
      );
    }

    final decision = gate.evaluate(evidence);
    final submission = decision.submission;
    if (!decision.accepted || submission == null) {
      return WorkshopLibrarySubmissionResult.reject(decision.reasons);
    }

    WorkshopLibraryIntakeBundle bundle;
    try {
      bundle = WorkshopLibraryIntakeBundle.build(
        submission: submission,
        files: payloadFiles,
      );
    } catch (error) {
      return WorkshopLibrarySubmissionResult.reject(
        <String>['bundle-rejected: ${error.runtimeType}'],
      );
    }

    final receipt = await submitBundle(bundle);
    return WorkshopLibrarySubmissionResult.success(receipt);
  }
}
