import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';

/// Executes the real local/offline Build Lab against an already prepared
/// Cantiere workspace.
///
/// This is intentionally a standalone Dart process so Flutter is free to take
/// its SDK/build locks. The dedicated CI workflow runs it after the guarded
/// production lifecycle has applied the generated source.
Future<void> main(List<String> args) async {
  if (args.length != 1 || args.first.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/workshop_local_build_acceptance.dart '
      '<workspace-path>',
    );
    exitCode = 64;
    return;
  }

  final workspace = Directory(args.first).absolute;
  if (!await workspace.exists()) {
    stderr.writeln(
      '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
      'reason=workspace_missing path=${workspace.path}',
    );
    exitCode = 66;
    return;
  }

  final flutterExecutable =
      Platform.environment['CANTIERE_FLUTTER_EXECUTABLE']?.trim();
  final dartExecutable =
      Platform.environment['CANTIERE_DART_EXECUTABLE']?.trim();

  if (flutterExecutable == null || flutterExecutable.isEmpty) {
    stderr.writeln(
      '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
      'reason=flutter_executable_missing',
    );
    exitCode = 78;
    return;
  }
  if (dartExecutable == null || dartExecutable.isEmpty) {
    stderr.writeln(
      '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
      'reason=dart_executable_missing',
    );
    exitCode = 78;
    return;
  }

  final provider = WorkshopLocalBuildProvider(
    configuration: WorkshopLocalBuildConfiguration(
      flutterExecutable: flutterExecutable,
      dartExecutable: dartExecutable,
      timeout: const Duration(minutes: 25),
    ),
  );

  try {
    stdout.writeln(
      '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=running '
      'target=android offline=true clean=true',
    );

    final result = await provider.build(
      WorkshopBuildRequest(
        id: 'cantiere-first-app-local-build',
        projectId: 'cantiere-first-app',
        projectPath: workspace.path,
        target: WorkshopBuildTarget.android,
        mode: WorkshopBuildExecutionMode.offlineLocal,
        cleanBuild: true,
        runFormatter: true,
        runAnalyzer: true,
        runTests: true,
      ),
    );

    if (result.stdout.isNotEmpty) {
      stdout.write(result.stdout);
    }
    if (result.stderr.isNotEmpty) {
      stderr.write(result.stderr);
    }

    if (!result.succeeded || !result.hasArtifact) {
      stderr.writeln(
        '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
        'build_status=${result.status.name} '
        'errors=${result.errors.join(',')} '
        'message=${result.message ?? ''}',
      );
      exitCode = 1;
      return;
    }

    final artifact = File(result.artifactPath!);
    if (!await artifact.exists()) {
      stderr.writeln(
        '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
        'reason=artifact_missing path=${result.artifactPath}',
      );
      exitCode = 1;
      return;
    }

    final bytes = await artifact.length();
    if (bytes <= 0) {
      stderr.writeln(
        '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=failed '
        'reason=artifact_empty path=${artifact.path}',
      );
      exitCode = 1;
      return;
    }

    stdout.writeln(
      '[WORKSHOP_LOCAL_BUILD_ACCEPTANCE] status=ready '
      'artifact=${artifact.path} bytes=$bytes',
    );
  } finally {
    await provider.dispose();
  }
}
