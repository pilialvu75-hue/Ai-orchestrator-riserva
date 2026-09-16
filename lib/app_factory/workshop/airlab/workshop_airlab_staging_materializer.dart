import 'package:ai_orchestrator/app_factory/workshop/workshop_task_contract.dart';

import 'workshop_airlab_contract.dart';

/// Controlled result of applying untrusted AIrLab operations to Cantiere staging.
///
/// This contract is deliberately platform-agnostic. Native filesystems, browser
/// storage, or future remote sandboxes can implement the same boundary without
/// changing the AIrLab protocol or the Workshop executor.
final class WorkshopAirLabStagingResult {
  const WorkshopAirLabStagingResult({
    required this.changedFiles,
    required this.createdCount,
    required this.updatedCount,
    required this.deletedCount,
    required this.totalPayloadBytes,
  });

  final List<String> changedFiles;
  final int createdCount;
  final int updatedCount;
  final int deletedCount;
  final int totalPayloadBytes;

  int get operationCount => createdCount + updatedCount + deletedCount;
}

/// Typed failure raised when AIrLab output is rejected before or during staging.
final class WorkshopAirLabStagingException implements Exception {
  const WorkshopAirLabStagingException(
    this.message, {
    required this.code,
    this.path,
  });

  final String message;
  final String code;
  final String? path;

  @override
  String toString() => 'WorkshopAirLabStagingException($code): $message';
}

/// Materializes validated AIrLab file operations inside an assigned staging root.
///
/// Implementations MUST treat every operation as untrusted input and MUST NOT
/// promote staged changes to the real repository. Promotion remains owned by the
/// normal Cantiere review/approval boundary.
abstract interface class WorkshopAirLabStagingMaterializer {
  Future<WorkshopAirLabStagingResult> materialize({
    required String stagingRoot,
    required List<WorkshopAirLabFileOperation> operations,
    required WorkshopTaskFileScope fileScope,
  });
}
