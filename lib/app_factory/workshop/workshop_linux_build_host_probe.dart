import 'dart:async';
import 'dart:io';

/// Configuration for the native host tools required by a Flutter Linux build.
///
/// This probe deliberately checks only the generic Linux desktop prerequisites.
/// Project-specific plugin libraries remain the responsibility of the concrete
/// project/build diagnostics.
final class WorkshopLinuxBuildHostProbeConfiguration {
  const WorkshopLinuxBuildHostProbeConfiguration({
    this.clangExecutable = 'clang',
    this.cmakeExecutable = 'cmake',
    this.ninjaExecutable = 'ninja',
    this.pkgConfigExecutable = 'pkg-config',
    this.gtkPkgConfigModule = 'gtk+-3.0',
    this.environment = const <String, String>{},
    this.timeout = const Duration(seconds: 10),
  });

  final String clangExecutable;
  final String cmakeExecutable;
  final String ninjaExecutable;
  final String pkgConfigExecutable;
  final String gtkPkgConfigModule;
  final Map<String, String> environment;
  final Duration timeout;
}

final class WorkshopLinuxProbeCommandResult {
  const WorkshopLinuxProbeCommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final String? error;

  bool get succeeded => exitCode == 0;
}

typedef WorkshopLinuxProbeCommandRunner =
    Future<WorkshopLinuxProbeCommandResult> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// Result of a Linux desktop build-host inspection.
final class WorkshopLinuxBuildHostCheck {
  const WorkshopLinuxBuildHostCheck({
    required this.available,
    required this.missingComponents,
    required this.details,
    required this.message,
  });

  final bool available;
  final List<String> missingComponents;
  final Map<String, String> details;
  final String message;
}

/// Verifies that the current host can actually execute a Flutter Linux build.
///
/// Merely finding the Flutter executable is not sufficient: the Linux desktop
/// toolchain also requires clang, CMake, Ninja, pkg-config and GTK development
/// metadata. The probe is read-only and never installs or downloads anything.
final class WorkshopLinuxBuildHostProbe {
  WorkshopLinuxBuildHostProbe({
    WorkshopLinuxBuildHostProbeConfiguration configuration =
        const WorkshopLinuxBuildHostProbeConfiguration(),
    WorkshopLinuxProbeCommandRunner? commandRunner,
    bool Function()? linuxHostProvider,
  })  : _configuration = configuration,
        _commandRunner = commandRunner,
        _linuxHostProvider = linuxHostProvider ?? (() => Platform.isLinux);

  final WorkshopLinuxBuildHostProbeConfiguration _configuration;
  final WorkshopLinuxProbeCommandRunner? _commandRunner;
  final bool Function() _linuxHostProvider;

  Future<WorkshopLinuxBuildHostCheck> inspect() async {
    if (!_linuxHostProvider()) {
      return const WorkshopLinuxBuildHostCheck(
        available: false,
        missingComponents: <String>['linux_build_host'],
        details: <String, String>{},
        message: 'Linux desktop builds require a Linux host.',
      );
    }

    final checks = await Future.wait<_ProbeCheck>(<Future<_ProbeCheck>>[
      _checkCommand(
        component: 'clang',
        executable: _configuration.clangExecutable,
        arguments: const <String>['--version'],
      ),
      _checkCommand(
        component: 'cmake',
        executable: _configuration.cmakeExecutable,
        arguments: const <String>['--version'],
      ),
      _checkCommand(
        component: 'ninja',
        executable: _configuration.ninjaExecutable,
        arguments: const <String>['--version'],
      ),
      _checkCommand(
        component: 'pkg_config',
        executable: _configuration.pkgConfigExecutable,
        arguments: const <String>['--version'],
      ),
      _checkCommand(
        component: 'gtk3_development',
        executable: _configuration.pkgConfigExecutable,
        arguments: <String>[
          '--exists',
          _configuration.gtkPkgConfigModule,
        ],
      ),
    ]);

    final missing = <String>[
      for (final check in checks)
        if (!check.available) check.component,
    ];
    final details = <String, String>{
      for (final check in checks)
        if (check.detail != null && check.detail!.isNotEmpty)
          check.component: check.detail!,
    };

    return WorkshopLinuxBuildHostCheck(
      available: missing.isEmpty,
      missingComponents: List<String>.unmodifiable(missing),
      details: Map<String, String>.unmodifiable(details),
      message: missing.isEmpty
          ? 'Linux desktop build host prerequisites are available.'
          : 'Linux desktop build host is incomplete: ${missing.join(', ')}.',
    );
  }

  Future<_ProbeCheck> _checkCommand({
    required String component,
    required String executable,
    required List<String> arguments,
  }) async {
    final result = await _run(executable, arguments);
    final output = result.stdout.trim().isNotEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    final detail = output.isNotEmpty
        ? output.split(RegExp(r'\r?\n')).first.trim()
        : result.error;
    return _ProbeCheck(
      component: component,
      available: result.succeeded,
      detail: detail,
    );
  }

  Future<WorkshopLinuxProbeCommandResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    final environment = <String, String>{
      ...Platform.environment,
      ..._configuration.environment,
    };
    final customRunner = _commandRunner;
    if (customRunner != null) {
      return customRunner(executable, arguments, environment);
    }

    try {
      final process = await Process.run(
        executable,
        arguments,
        environment: environment,
        runInShell: false,
      ).timeout(_configuration.timeout);
      return WorkshopLinuxProbeCommandResult(
        exitCode: process.exitCode,
        stdout: process.stdout.toString(),
        stderr: process.stderr.toString(),
      );
    } on TimeoutException catch (error) {
      return WorkshopLinuxProbeCommandResult(
        exitCode: -1,
        error: error.toString(),
      );
    } on ProcessException catch (error) {
      return WorkshopLinuxProbeCommandResult(
        exitCode: -1,
        error: error.message,
      );
    } catch (error) {
      return WorkshopLinuxProbeCommandResult(
        exitCode: -1,
        error: error.toString(),
      );
    }
  }
}

final class _ProbeCheck {
  const _ProbeCheck({
    required this.component,
    required this.available,
    required this.detail,
  });

  final String component;
  final bool available;
  final String? detail;
}
