import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_detector.dart';

void main() {
  test(
      'non UTF-8 tool diagnostics preserve failure without crashing inspection or build',
      () async {
    final root = await Directory.systemTemp.createTemp('cantiere-output-');
    final tool = File(
        '${root.path}/${Platform.isWindows ? 'flutter.bat' : 'flutter.sh'}');
    await File('${root.path}/oem.bin').writeAsBytes([0x82, 0x0a]);
    if (Platform.isWindows) {
      await tool.writeAsString('@echo off\r\n'
          'if "%1"=="--version" (\r\n'
          'echo {"frameworkVersion":"3.47.5"}\r\nexit /b 0\r\n)\r\n'
          'type "%~dp0oem.bin" 1>&2\r\nexit /b 7\r\n');
    } else {
      await tool.writeAsString('#!/bin/sh\n'
          'if [ "\$1" = "--version" ]; then\n'
          'echo \'{"frameworkVersion":"3.47.5"}\'\nexit 0\nfi\n'
          'printf "\\202\\n" >&2\nexit 7\n');
      expect((await Process.run('chmod', ['+x', tool.path])).exitCode, 0);
    }
    final detector = WorkshopLocalToolchainDetector(
      configuration: WorkshopLocalToolchainDetectorConfiguration(
        flutterExecutable: tool.path,
        dartExecutable: tool.path,
        javaExecutable: tool.path,
        timeout: const Duration(seconds: 5),
      ),
    );
    final report = await detector.inspectAll();
    expect(report.flutterAvailable, isTrue);
    expect(report.javaAvailable, isFalse);
    final provider = WorkshopLocalBuildProvider(
      configuration: WorkshopLocalBuildConfiguration(
          flutterExecutable: tool.path, timeout: const Duration(seconds: 5)),
    );
    try {
      final result = await provider.build(WorkshopBuildRequest(
        id: 'oem-error',
        projectId: 'project',
        projectPath: root.path,
        target: WorkshopBuildTarget.android,
      ));
      expect(result.status, WorkshopBuildStatus.failed);
      expect(result.exitCode, 7);
      expect(result.errors, contains('local_pub_get_offline_failed'));
      expect(result.stderr, contains(String.fromCharCode(0xfffd)));
      expect(result.artifactPath, isNull);
    } finally {
      await provider.dispose();
    }
  });
}
