import 'workshop_library_submission.dart';

/// Transport boundary used by the Cantiere to deliver an already accepted
/// Library intake submission.
///
/// Implementations may use GitHub, a service endpoint, or another authenticated
/// transport. Credentials deliberately live outside this domain layer.
abstract interface class WorkshopLibraryIntakeTransport {
  Future<WorkshopLibraryTransportReceipt> submit(
    WorkshopLibraryTransportRequest request,
  );
}

final class WorkshopLibraryTransportRequest {
  const WorkshopLibraryTransportRequest({
    required this.repository,
    required this.pin,
    required this.manifestPath,
    required this.manifest,
    required this.payloadSha256,
    required this.sourceProjectId,
    required this.sourceTaskId,
  });

  final String repository;
  final String pin;
  final String manifestPath;
  final Map<String, Object?> manifest;
  final String payloadSha256;
  final String sourceProjectId;
  final String? sourceTaskId;
}

final class WorkshopLibraryTransportReceipt {
  const WorkshopLibraryTransportReceipt({
    required this.accepted,
    this.remoteReference,
    this.message,
  });

  final bool accepted;
  final String? remoteReference;
  final String? message;
}

final class WorkshopLibraryBridgeResult {
  const WorkshopLibraryBridgeResult._({
    required this.transmitted,
    required this.reasons,
    this.receipt,
  });

  final bool transmitted;
  final List<String> reasons;
  final WorkshopLibraryTransportReceipt? receipt;

  factory WorkshopLibraryBridgeResult.success(
    WorkshopLibraryTransportReceipt receipt,
  ) => WorkshopLibraryBridgeResult._(
        transmitted: true,
        reasons: const <String>[],
        receipt: receipt,
      );

  factory WorkshopLibraryBridgeResult.reject(List<String> reasons) =>
      WorkshopLibraryBridgeResult._(
        transmitted: false,
        reasons: List<String>.unmodifiable(reasons),
      );
}

/// Fail-closed bridge between a Cantiere submission decision and the external
/// Module Library transport.
///
/// The bridge cannot create or certify a candidate. It only transports output
/// that has already passed [WorkshopLibrarySubmissionGate], and it defensively
/// re-checks the immutable intake invariants before invoking the transport.
final class WorkshopLibraryIntakeBridge {
  const WorkshopLibraryIntakeBridge({
    required this.transport,
    this.repository = 'pilialvu75-hue/AI-Orchestrator-Module-Library',
  });

  final WorkshopLibraryIntakeTransport transport;
  final String repository;

  static final RegExp _sha256 = RegExp(r'^[A-Fa-f0-9]{64}$');

  Future<WorkshopLibraryBridgeResult> transmit(
    WorkshopLibraryCaptureDecision decision,
  ) async {
    final submission = decision.submission;
    if (!decision.accepted || submission == null) {
      return WorkshopLibraryBridgeResult.reject(
        const <String>['submission-not-accepted'],
      );
    }

    final reasons = <String>[];
    final expectedPath =
        'intake/${submission.assetId}/${submission.version}/manifest.json';

    if (submission.manifestPath != expectedPath) {
      reasons.add('invalid-intake-path');
    }
    if (submission.manifest['status'] != 'discovered') {
      reasons.add('invalid-intake-status');
    }
    if (!_sha256.hasMatch(submission.payloadSha256)) {
      reasons.add('invalid-payload-sha256');
    }
    if (repository.trim().isEmpty) {
      reasons.add('missing-library-repository');
    }

    if (reasons.isNotEmpty) {
      return WorkshopLibraryBridgeResult.reject(reasons);
    }

    final receipt = await transport.submit(
      WorkshopLibraryTransportRequest(
        repository: repository,
        pin: submission.pin,
        manifestPath: submission.manifestPath,
        manifest: Map<String, Object?>.unmodifiable(submission.manifest),
        payloadSha256: submission.payloadSha256,
        sourceProjectId: submission.sourceProjectId,
        sourceTaskId: submission.sourceTaskId,
      ),
    );

    if (!receipt.accepted) {
      return WorkshopLibraryBridgeResult.reject(
        <String>[
          'transport-rejected',
          if (receipt.message != null && receipt.message!.trim().isNotEmpty)
            receipt.message!.trim(),
        ],
      );
    }

    return WorkshopLibraryBridgeResult.success(receipt);
  }
}
