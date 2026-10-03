import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';

/// Gives a remote build a deterministic provider-facing identity while keeping
/// the caller-facing request id unchanged.
///
/// The Dashboard historically creates a fresh timestamp id for every build
/// invocation. That is useful for UI events but cannot correlate the same
/// external build after an app/process restart. This decorator derives a closed
/// SHA-256 identity from the authoritative build intent and forwards that id to
/// the remote provider. Results are translated back to the caller id.
///
/// No source contents, prompts, credentials or raw filesystem path are exposed
/// in the resulting id; all identity inputs are inside the hash.
final class WorkshopStableBuildRequestProvider implements WorkshopBuildProvider {
  WorkshopStableBuildRequestProvider({
    required WorkshopBuildProvider inner,
  }) : _inner = inner;

  final WorkshopBuildProvider _inner;
  final Map<String, String> _activeRequestIds = <String, String>{};

  @override
  WorkshopBuildExecutionMode get executionMode => _inner.executionMode;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) =>
      _inner.inspectToolchain(target);

  @override
  Future<WorkshopBuildResult> build(WorkshopBuildRequest request) async {
    final stableId = WorkshopStableBuildRequestIdentity.forRequest(request);
    _activeRequestIds[request.id] = stableId;

    final stableRequest = WorkshopBuildRequest(
      id: stableId,
      projectId: request.projectId,
      projectPath: request.projectPath,
      target: request.target,
      appDisplayName: request.appDisplayName,
      mode: request.mode,
      runTests: request.runTests,
      runAnalyzer: request.runAnalyzer,
      runFormatter: request.runFormatter,
      cleanBuild: request.cleanBuild,
      arguments: List<String>.unmodifiable(request.arguments),
      environment: Map<String, String>.unmodifiable(request.environment),
    );

    try {
      final result = await _inner.build(stableRequest);
      return WorkshopBuildResult(
        requestId: request.id,
        target: result.target,
        status: result.status,
        startedAt: result.startedAt,
        finishedAt: result.finishedAt,
        artifactPath: result.artifactPath,
        message: result.message,
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
        testsPassed: result.testsPassed,
        analysisPassed: result.analysisPassed,
        formatPassed: result.formatPassed,
        warnings: result.warnings,
        errors: result.errors,
      );
    } finally {
      _activeRequestIds.remove(request.id);
    }
  }

  @override
  Future<void> cancel(String requestId) {
    return _inner.cancel(_activeRequestIds[requestId] ?? requestId);
  }
}

abstract final class WorkshopStableBuildRequestIdentity {
  static String forRequest(WorkshopBuildRequest request) {
    final environmentEntries = request.environment.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));

    final payload = jsonEncode(<String, Object?>{
      'schema': 1,
      'projectId': request.projectId.trim(),
      'projectPath': request.projectPath.trim(),
      'target': request.target.name,
      'appDisplayName': request.appDisplayName?.trim() ?? '',
      'mode': request.mode.name,
      'runTests': request.runTests,
      'runAnalyzer': request.runAnalyzer,
      'runFormatter': request.runFormatter,
      'cleanBuild': request.cleanBuild,
      'arguments': request.arguments,
      'environment': <String, String>{
        for (final entry in environmentEntries) entry.key: entry.value,
      },
    });
    final digest = sha256.convert(utf8.encode(payload)).toString();
    return 'build-v1-${digest.substring(0, 32)}';
  }
}
