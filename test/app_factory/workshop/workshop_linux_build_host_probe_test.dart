import 'package:ai_orchestrator/app_factory/workshop/workshop_linux_build_host_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLinuxBuildHostProbe', () {
    test('fails closed outside Linux', () async {
      final probe = WorkshopLinuxBuildHostProbe(
        linuxHostProvider: () => false,
        commandRunner: (_, __, ___) async {
          throw StateError('runner must not be called');
        },
      );

      final result = await probe.inspect();

      expect(result.available, isFalse);
      expect(result.missingComponents, <String>['linux_build_host']);
    });

    test('reports available only when every generic Linux prerequisite works',
        () async {
      final calls = <String>[];
      final probe = WorkshopLinuxBuildHostProbe(
        linuxHostProvider: () => true,
        commandRunner: (executable, arguments, environment) async {
          calls.add('$executable ${arguments.join(' ')}');
          return const WorkshopLinuxProbeCommandResult(
            exitCode: 0,
            stdout: 'tool version 1.0\n',
          );
        },
      );

      final result = await probe.inspect();

      expect(result.available, isTrue);
      expect(result.missingComponents, isEmpty);
      expect(calls, contains('clang --version'));
      expect(calls, contains('cmake --version'));
      expect(calls, contains('ninja --version'));
      expect(calls, contains('pkg-config --version'));
      expect(calls, contains('pkg-config --exists gtk+-3.0'));
    });

    test('identifies the exact missing native prerequisites', () async {
      final probe = WorkshopLinuxBuildHostProbe(
        linuxHostProvider: () => true,
        commandRunner: (executable, arguments, environment) async {
          final isMissingClang = executable == 'clang';
          final isMissingGtk = executable == 'pkg-config' &&
              arguments.length == 2 &&
              arguments.first == '--exists';
          if (isMissingClang || isMissingGtk) {
            return const WorkshopLinuxProbeCommandResult(
              exitCode: 1,
              stderr: 'missing',
            );
          }
          return const WorkshopLinuxProbeCommandResult(
            exitCode: 0,
            stdout: 'ok',
          );
        },
      );

      final result = await probe.inspect();

      expect(result.available, isFalse);
      expect(
        result.missingComponents,
        containsAll(<String>['clang', 'gtk3_development']),
      );
      expect(result.missingComponents, hasLength(2));
    });

    test('honours configured tool names and GTK module', () async {
      final calls = <String>[];
      final probe = WorkshopLinuxBuildHostProbe(
        configuration: const WorkshopLinuxBuildHostProbeConfiguration(
          clangExecutable: '/toolchain/clang',
          cmakeExecutable: '/toolchain/cmake',
          ninjaExecutable: '/toolchain/ninja',
          pkgConfigExecutable: '/toolchain/pkg-config',
          gtkPkgConfigModule: 'gtk-custom',
          environment: <String, String>{'CUSTOM_TOOLCHAIN': '1'},
        ),
        linuxHostProvider: () => true,
        commandRunner: (executable, arguments, environment) async {
          expect(environment['CUSTOM_TOOLCHAIN'], '1');
          calls.add('$executable ${arguments.join(' ')}');
          return const WorkshopLinuxProbeCommandResult(exitCode: 0);
        },
      );

      final result = await probe.inspect();

      expect(result.available, isTrue);
      expect(calls, contains('/toolchain/clang --version'));
      expect(calls, contains('/toolchain/pkg-config --exists gtk-custom'));
    });
  });
}
