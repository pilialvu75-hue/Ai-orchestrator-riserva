import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_execution_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_task_inference_pipeline.dart';

enum WorkshopDeviceAcceptanceStatus {
  pending,
  passed,
  failed,
}

enum WorkshopDeviceAcceptanceFailureStage {
  none,
  modelRuntime,
  parsing,
  review,
  validation,
  build,
  install,
  launch,
}

final class WorkshopDeviceAcceptanceReceipt {
  const WorkshopDeviceAcceptanceReceipt({
    required this.recordedAtUtc,
    required this.status,
    required this.failureStage,
    required this.hostVersion,
    required this.hostCommitSha,
    required this.platform,
    required this.projectId,
    required this.requestId,
    required this.modelAssignments,
    required this.promptSha256,
    required this.completedTasks,
    required this.totalTasks,
    required this.executionStatus,
    required this.reviewApproved,
    this.reviewSummary,
    this.reviewFindings = const <String>[],
    this.reviewWarnings = const <String>[],
    this.stagedDiffSha256,
    required this.validationValid,
    required this.buildStatus,
    required this.formatPassed,
    required this.analysisPassed,
    required this.testsPassed,
    required this.artifactSha256,
    required this.installAttempted,
    required this.installerOpened,
    required this.generatedAppOpened,
  });

  static const int schemaVersion = 1;

  final DateTime recordedAtUtc;
  final WorkshopDeviceAcceptanceStatus status;
  final WorkshopDeviceAcceptanceFailureStage failureStage;

  /// Version/build of the AI-Orchestrator APK running the Cantiere.
  final String hostVersion;

  /// Commit embedded by CI into the AI-Orchestrator APK.
  final String hostCommitSha;

  final String platform;
  final String projectId;
  final String requestId;

  /// Logical Workshop role -> configured model id. No prompt/output is stored.
  final Map<String, String> modelAssignments;

  /// Privacy-preserving fingerprint of the project goal/request prompt.
  final String? promptSha256;

  final int completedTasks;
  final int totalTasks;
  final String executionStatus;
  final bool? reviewApproved;
  final String? reviewSummary;
  final List<String> reviewFindings;
  final List<String> reviewWarnings;
  /// Privacy-preserving fingerprint of the staged file paths/types/content.
  final String? stagedDiffSha256;
  final bool? validationValid;
  final String? buildStatus;
  final bool? formatPassed;
  final bool? analysisPassed;
  final bool? testsPassed;

  /// SHA-256 of the generated application artifact, not the host app.
  final String? artifactSha256;

  final bool installAttempted;
  final bool installerOpened;

  /// Null means the human launch check has not happened yet.
  final bool? generatedAppOpened;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'recordedAtUtc': recordedAtUtc.toIso8601String(),
        'status': status.name,
        'failureStage': failureStage.name,
        'hostVersion': hostVersion,
        'hostCommitSha': hostCommitSha,
        'platform': platform,
        'projectId': projectId,
        'requestId': requestId,
        'modelAssignments': <String, String>{...modelAssignments},
        'promptSha256': promptSha256,
        'completedTasks': completedTasks,
        'totalTasks': totalTasks,
        'executionStatus': executionStatus,
        'reviewApproved': reviewApproved,
        'reviewSummary': reviewSummary,
        'reviewFindings': reviewFindings,
        'reviewWarnings': reviewWarnings,
        'stagedDiffSha256': stagedDiffSha256,
        'validationValid': validationValid,
        'buildStatus': buildStatus,
        'formatPassed': formatPassed,
        'analysisPassed': analysisPassed,
        'testsPassed': testsPassed,
        'artifactSha256': artifactSha256,
        'installAttempted': installAttempted,
        'installerOpened': installerOpened,
        'generatedAppOpened': generatedAppOpened,
      };

  String toPrettyJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  factory WorkshopDeviceAcceptanceReceipt.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException(
        'Unsupported Workshop device acceptance receipt version.',
      );
    }

    final recordedAt =
        DateTime.tryParse(json['recordedAtUtc']?.toString() ?? '');
    final status = _enumByName(
      WorkshopDeviceAcceptanceStatus.values,
      json['status'],
    );
    final failureStage = _enumByName(
      WorkshopDeviceAcceptanceFailureStage.values,
      json['failureStage'],
    );
    final models = json['modelAssignments'];

    if (recordedAt == null ||
        status == null ||
        failureStage == null ||
        models is! Map) {
      throw const FormatException(
        'Invalid Workshop device acceptance receipt.',
      );
    }

    return WorkshopDeviceAcceptanceReceipt(
      recordedAtUtc: recordedAt.toUtc(),
      status: status,
      failureStage: failureStage,
      hostVersion: json['hostVersion']?.toString() ?? 'unknown',
      hostCommitSha: json['hostCommitSha']?.toString() ?? 'unknown',
      platform: json['platform']?.toString() ?? 'unknown',
      projectId: json['projectId']?.toString() ?? '',
      requestId: json['requestId']?.toString() ?? '',
      modelAssignments: Map<String, String>.unmodifiable(
        models.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
      ),
      promptSha256: json['promptSha256']?.toString(),
      completedTasks: _int(json['completedTasks']),
      totalTasks: _int(json['totalTasks']),
      executionStatus: json['executionStatus']?.toString() ?? 'unknown',
      reviewApproved: _boolOrNull(json['reviewApproved']),
      reviewSummary: json['reviewSummary']?.toString(),
      reviewFindings: _stringList(json['reviewFindings']),
      reviewWarnings: _stringList(json['reviewWarnings']),
      stagedDiffSha256: json['stagedDiffSha256']?.toString(),
      validationValid: _boolOrNull(json['validationValid']),
      buildStatus: json['buildStatus']?.toString(),
      formatPassed: _boolOrNull(json['formatPassed']),
      analysisPassed: _boolOrNull(json['analysisPassed']),
      testsPassed: _boolOrNull(json['testsPassed']),
      artifactSha256: json['artifactSha256']?.toString(),
      installAttempted: json['installAttempted'] == true,
      installerOpened: json['installerOpened'] == true,
      generatedAppOpened: _boolOrNull(json['generatedAppOpened']),
    );
  }

  static T? _enumByName<T extends Enum>(
    Iterable<T> values,
    Object? raw,
  ) {
    final name = raw?.toString();
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  static bool? _boolOrNull(Object? value) =>
      value is bool ? value : null;

  static List<String> _stringList(Object? value) => value is List
      ? List<String>.unmodifiable(value.map((item) => item.toString()))
      : const <String>[];
}

abstract final class WorkshopDeviceAcceptanceScope {
  static WorkshopDeviceAcceptanceReceipt? forProject({
    required WorkshopDeviceAcceptanceReceipt? receipt,
    required String? projectId,
  }) {
    final normalizedProjectId = projectId?.trim();
    if (receipt == null ||
        normalizedProjectId == null ||
        normalizedProjectId.isEmpty ||
        receipt.projectId.trim() != normalizedProjectId) {
      return null;
    }
    return receipt;
  }
}

abstract final class WorkshopAcceptanceFingerprint {
  static String? sha256Text(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return sha256.convert(utf8.encode(normalized)).toString();
  }
}

abstract final class WorkshopHostBuildIdentity {
  static const String _rawCommitSha = String.fromEnvironment(
    'AI_ORCHESTRATOR_COMMIT_SHA',
    defaultValue: 'unknown',
  );

  static String get commitSha => normalizeCommitSha(_rawCommitSha);

  static String normalizeCommitSha(String raw) {
    final normalized = raw.trim().toLowerCase();
    return RegExp(r'^[0-9a-f]{40}$').hasMatch(normalized)
        ? normalized
        : 'unknown';
  }
}

final class WorkshopDeviceAcceptanceClassification {
  const WorkshopDeviceAcceptanceClassification({
    required this.status,
    required this.failureStage,
  });

  final WorkshopDeviceAcceptanceStatus status;
  final WorkshopDeviceAcceptanceFailureStage failureStage;
}

abstract final class WorkshopDeviceAcceptanceClassifier {
  static WorkshopDeviceAcceptanceClassification classify({
    required WorkshopProductionExecutionStatus executionStatus,
    required Object? executionError,
    required WorkshopTaskInferenceResult? inferenceResult,
    required WorkshopBuildResult? buildResult,
    required bool buildVerified,
    required bool installAttempted,
    required bool installerOpened,
    required bool? generatedAppOpened,
  }) {
    if (executionStatus == WorkshopProductionExecutionStatus.failed) {
      return WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: executionError is FormatException
            ? WorkshopDeviceAcceptanceFailureStage.parsing
            : WorkshopDeviceAcceptanceFailureStage.modelRuntime,
      );
    }

    if (inferenceResult != null && !inferenceResult.review.approved) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.review,
      );
    }

    if (inferenceResult?.review.approved == true &&
        inferenceResult?.validation?.valid == false) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.validation,
      );
    }

    if (buildResult != null && !buildVerified) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.build,
      );
    }

    if (installAttempted && !installerOpened) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.install,
      );
    }

    if (installerOpened && generatedAppOpened == false) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.failed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.launch,
      );
    }

    if (installerOpened && generatedAppOpened == true) {
      return const WorkshopDeviceAcceptanceClassification(
        status: WorkshopDeviceAcceptanceStatus.passed,
        failureStage: WorkshopDeviceAcceptanceFailureStage.none,
      );
    }

    return const WorkshopDeviceAcceptanceClassification(
      status: WorkshopDeviceAcceptanceStatus.pending,
      failureStage: WorkshopDeviceAcceptanceFailureStage.none,
    );
  }
}

final class WorkshopDeviceAcceptanceStore {
  WorkshopDeviceAcceptanceStore(this._preferences);

  static const String _latestKey =
      'workshop.device.acceptance.latest.v1';

  final SharedPreferences _preferences;

  static Future<WorkshopDeviceAcceptanceStore> open() async =>
      WorkshopDeviceAcceptanceStore(
        await SharedPreferences.getInstance(),
      );

  Future<void> save(WorkshopDeviceAcceptanceReceipt receipt) async {
    await _preferences.setString(
      _latestKey,
      jsonEncode(receipt.toJson()),
    );
  }

  WorkshopDeviceAcceptanceReceipt? loadLatest() {
    final raw = _preferences.getString(_latestKey);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return WorkshopDeviceAcceptanceReceipt.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } on Object {
      return null;
    }
  }
}
