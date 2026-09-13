import 'dart:convert';

import 'workshop_library_intake_bridge.dart';

/// Deterministic hand-off artifact consumed by an authenticated executor that
/// lives outside the Flutter/domain layer.
final class WorkshopLibraryOutboxEnvelope {
  const WorkshopLibraryOutboxEnvelope({
    required this.repository,
    required this.pin,
    required this.manifestPath,
    required this.payloadSha256,
    required this.sourceProjectId,
    required this.sourceTaskId,
    required this.manifest,
  });

  final String repository;
  final String pin;
  final String manifestPath;
  final String payloadSha256;
  final String sourceProjectId;
  final String? sourceTaskId;
  final Map<String, Object?> manifest;

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': 'ai-orchestrator.library-intake-outbox.v1',
        'repository': repository,
        'pin': pin,
        'manifest_path': manifestPath,
        'payload_sha256': payloadSha256,
        'source_project_id': sourceProjectId,
        if (sourceTaskId != null) 'source_task_id': sourceTaskId,
        'manifest': manifest,
      };

  String encode() => jsonEncode(toJson());
}

/// Transport implementation that does not perform network or credential work.
///
/// Instead it emits a deterministic envelope to a caller-supplied sink. The
/// sink may persist it locally, enqueue it to a backend, or hand it to CI. A
/// separate authenticated executor is responsible for writing into the private
/// Module Library repository.
final class WorkshopLibraryOutboxTransport
    implements WorkshopLibraryIntakeTransport {
  const WorkshopLibraryOutboxTransport({required this.write});

  final Future<String?> Function(WorkshopLibraryOutboxEnvelope envelope) write;

  @override
  Future<WorkshopLibraryTransportReceipt> submit(
    WorkshopLibraryTransportRequest request,
  ) async {
    final envelope = WorkshopLibraryOutboxEnvelope(
      repository: request.repository,
      pin: request.pin,
      manifestPath: request.manifestPath,
      payloadSha256: request.payloadSha256,
      sourceProjectId: request.sourceProjectId,
      sourceTaskId: request.sourceTaskId,
      manifest: Map<String, Object?>.unmodifiable(request.manifest),
    );

    final reference = await write(envelope);
    if (reference == null || reference.trim().isEmpty) {
      return const WorkshopLibraryTransportReceipt(
        accepted: false,
        message: 'outbox-write-rejected',
      );
    }

    return WorkshopLibraryTransportReceipt(
      accepted: true,
      remoteReference: reference.trim(),
    );
  }
}
