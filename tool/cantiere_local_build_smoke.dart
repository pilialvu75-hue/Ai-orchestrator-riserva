import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';

/// CI acceptance smoke for the real offline-local Build Lab executor.
///
/// The workspace must already exist and all required packages must already be
/// present in the local pub cache. No network-backed dependency resolution is
/// allowed by this smoke.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/cantiere_local_build_smoke.dart <workspace-path>',
    );
    exitCode = 64;
    return;
  }

  final workspace = Directory(args.single).absolute;
  if (!await workspace.exists()) {
    stderr.writeln('Workspace does not exist: ${workspace.path}');
    exitCode = 66;
    return;
  }

  final flutterExecutable =
      Platform.environment['CANTIERE_FLUTTER_EXECUTABLE']?.trim();
  final dartExecutable =
      Platform.environment['CANTIERE_DART_EXECUTABLE']?.trim();

  if (flutterExecutable == null || flutterExecutable.isEmpty) {
    stderr.writeln('CANTIERE_FLUTTER_EXECUTABLE is required.');
    exitCode = 78;
    return;
  }
  if (dartExecutable == null || dartExecutable.isEmpty) {
    stderr.writeln('CANTIERE_DART_EXECUTABLE is required.');
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
      '[LOCAL_BUILD_SMOKE] stage=build status=running mode=offlineLocal',
    );

    final result = await provider.build(
      WorkshopBuildRequest(
        id: 'cantiere-local-build-smoke',
        projectId: 'cantiere-first-app',
        projectPath: workspace.path,
        target: WorkshopBuildTarget.android,
        mode: WorkshopBuildExecutionMode.offlineLocal,
        runFormatter: true,
        runAnalyzer: true,
        runTests: true,
        cleanBuild: true,
        arguments: const <String>['--release'],
      ),
    );

    if (result.stdout.trim().isNotEmpty) {
      stdout.write(result.stdout);
    }
    if (result.stderr.trim().isNotEmpty) {
      stderr.write(result.stderr);
    }

    if (!result.succeeded || !result.hasArtifact) {
      stderr.writeln(
        '[LOCAL_BUILD_SMOKE] stage=build status=failed '
        'message=${result.message} errors=${result.errors}',
      );
      exitCode = result.exitCode == null || result.exitCode == 0
          ? 1
          : result.exitCode!;
      return;
    }

    final artifact = File(result.artifactPath!);
    if (!await artifact.exists()) {
      stderr.writeln(
        '[LOCAL_BUILD_SMOKE] stage=artifact status=missing '
        'path=${artifact.path}',
      );
      exitCode = 2;
      return;
    }

    final bytes = await artifact.length();
    if (bytes <= 0) {
      stderr.writeln(
        '[LOCAL_BUILD_SMOKE] stage=artifact status=empty '
        'path=${artifact.path}',
      );
      exitCode = 3;
      return;
    }

    stdout.writeln(
      '[LOCAL_BUILD_SMOKE] stage=artifact status=ready '
      'bytes=$bytes path=${artifact.path}',
    );
  } finally {
    await provider.dispose();
  }
}
