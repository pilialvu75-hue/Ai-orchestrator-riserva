import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorkshopBuildRequest request({
    WorkshopBuildTarget target = WorkshopBuildTarget.linux,
    bool cleanBuild = false,
    bool runFormatter = true,
    bool runAnalyzer = true,
    bool runTests = true,
  }) {
    return WorkshopBuildRequest(
      id: 'offline-plan',
      projectId: 'project:test',
      projectPath: '/workspace/project',
      target: target,
      mode: WorkshopBuildExecutionMode.offlineLocal,
      cleanBuild: cleanBuild,
      runFormatter: runFormatter,
      runAnalyzer: runAnalyzer,
      runTests: runTests,
    );
  }

  group('WorkshopLocalBuildPlanner', () {
    test('always resolves dependencies explicitly offline before validation',
        () {
      final plan = WorkshopLocalBuildPlanner.plan(
        request(
          runFormatter: false,
          runAnalyzer: false,
          runTests: false,
        ),
      );

      expect(
        plan.map((step) => step.name).toList(),
        <String>['pub_get_offline', 'build'],
      );
      expect(
        plan.first.arguments,
        <String>['pub', 'get', '--offline'],
      );
      expect(
        plan.first.executable,
        WorkshopLocalBuildExecutable.flutter,
      );
      expect(plan.last.arguments, contains('--no-pub'));
    });

    test('clean build runs clean before offline dependency resolution', () {
      final plan = WorkshopLocalBuildPlanner.plan(
        request(
          cleanBuild: true,
          runFormatter: false,
          runAnalyzer: false,
          runTests: false,
        ),
      );

      expect(
        plan.take(2).map((step) => step.name).toList(),
        <String>['clean', 'pub_get_offline'],
      );
      expect(plan.first.arguments, <String>['clean']);
    });

    test('formatter uses Dart and never asks the Flutter CLI to format', () {
      final plan = WorkshopLocalBuildPlanner.plan(
        request(
          runAnalyzer: false,
          runTests: false,
        ),
      );

      final format = plan.singleWhere((step) => step.name == 'format');
      expect(format.executable, WorkshopLocalBuildExecutable.dart);
      expect(
        format.arguments,
        <String>[
          'format',
          '--output=none',
          '--set-exit-if-changed',
          '.',
        ],
      );
    });

    test('analyze test and build cannot trigger implicit pub resolution', () {
      final plan = WorkshopLocalBuildPlanner.plan(request());

      for (final name in <String>['analyze', 'test', 'build']) {
        final step = plan.singleWhere((candidate) => candidate.name == name);
        expect(
          step.arguments,
          contains('--no-pub'),
          reason: '$name must not perform implicit network-capable pub work',
        );
      }
    });

    test('maps every Flutter build target deterministically', () {
      final expected = <WorkshopBuildTarget, String>{
        WorkshopBuildTarget.android: 'apk',
        WorkshopBuildTarget.windows: 'windows',
        WorkshopBuildTarget.linux: 'linux',
        WorkshopBuildTarget.macos: 'macos',
        WorkshopBuildTarget.ios: 'ios',
        WorkshopBuildTarget.web: 'web',
      };

      for (final entry in expected.entries) {
        final plan = WorkshopLocalBuildPlanner.plan(
          request(
            target: entry.key,
            runFormatter: false,
            runAnalyzer: false,
            runTests: false,
          ),
        );
        final build = plan.singleWhere((step) => step.name == 'build');
        expect(build.arguments[1], entry.value);
      }
    });
  });
}
