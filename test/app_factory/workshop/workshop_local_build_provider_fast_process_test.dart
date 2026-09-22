import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'fast local tool commands still complete and return the built artifact',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workshop-local-fast-process-',
      );
      final project = Directory(
        '${root.path}${Platform.pathSeparator}project',
      );
      await project.create(recursive: true);

      final tool = File(
        '${root.path}${Platform.pathSeparator}'
        '${Platform.isWindows ? 'fake_flutter.bat' : 'fake_flutter.sh'}',
      );

      if (Platform.isWindows) {
        await tool.writeAsString(
          '@echo off\r\n'
          'if "%1"=="--version" (\r\n'
          '  echo {"frameworkVersion":"3.47.5"}\r\n'
          '  exit /b 0\r\n'
          ')\r\n'
          'if "%1"=="build" (\r\n'
          '  if not exist build\\app\\outputs\\flutter-apk '
          'mkdir build\\app\\outputs\\flutter-apk\r\n'
          '  > build\\app\\outputs\\flutter-apk\\app-release.apk '
          'echo apk\r\n'
          ')\r\n'
          'echo ok\r\n'
          'exit /b 0\r\n',
          flush: true,
        );
      } else {
        await tool.writeAsString(
          '#!/usr/bin/env sh\n'
          'set -eu\n'
          'if [ "\${1:-}" = "--version" ]; then\n'
          '  echo \'{"frameworkVersion":"3.47.5"}\'\n'
          '  exit 0\n'
          'fi\n'
          'if [ "\${1:-}" = "build" ]; then\n'
          '  mkdir -p build/app/outputs/flutter-apk\n'
          '  printf apk > build/app/outputs/flutter-apk/app-release.apk\n'
          'fi\n'
          'printf "ok\\n"\n'
          'exit 0\n',
          flush: true,
        );
        final chmod = await Process.run('chmod', <String>['+x', tool.path]);
        expect(chmod.exitCode, 0);
      }

      final provider = WorkshopLocalBuildProvider(
        configuration: WorkshopLocalBuildConfiguration(
          flutterExecutable: tool.path,
          dartExecutable: tool.path,
          timeout: const Duration(seconds: 5),
        ),
      );

      try {
        final result = await provider.build(
          WorkshopBuildRequest(
            id: 'fast-process',
            projectId: 'test-project',
            projectPath: project.path,
            target: WorkshopBuildTarget.android,
            mode: WorkshopBuildExecutionMode.offlineLocal,
            cleanBuild: true,
            arguments: const <String>['--release'],
          ),
        );

        expect(result.succeeded, isTrue);
        expect(result.hasArtifact, isTrue);
        expect(result.artifactPath, endsWith('app-release.apk'));
        expect(await File(result.artifactPath!).exists(), isTrue);
        expect(
          result.stdout,
          contains('step=build status=completed exit_code=0'),
        );
      } finally {
        await provider.dispose();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
