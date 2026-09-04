import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';

/// Configurazione della Flutter SDK locale.
///
/// Il percorso deve puntare a una Flutter SDK già disponibile sul dispositivo
/// o nell'ambiente che ospita il Cantiere.
///
/// Questo provider NON scarica la SDK: la gestione/download della toolchain
/// verrà mantenuta separata dal motore di build.
final class WorkshopLocalBuildConfiguration {
  const WorkshopLocalBuildConfiguration({
    required this.flutterExecutable,
    this.environment = const <String, String>{},
    this.timeout = const Duration(minutes: 30),
  });

  /// Percorso assoluto dell'eseguibile Flutter.
  ///
  /// Esempi:
  /// Linux:
  ///   /data/.../flutter/bin/flutter
  ///
  /// Windows:
  ///   C:\...\flutter\bin\flutter.bat
  ///
  /// Android:
  ///   percorso della toolchain locale eventualmente installata
  ///   dal futuro LocalToolchainManager.
  final String flutterExecutable;

  final Map<String, String> environment;

  final Duration timeout;
}

/// Provider di build Flutter locale/offline.
///
/// Responsabilità:
/// - verificare che Flutter sia realmente eseguibile;
/// - verificare il progetto;
/// - eseguire formatter/analyzer/test/build;
/// - raccogliere stdout/stderr/exit code;
/// - individuare l'artifact prodotto;
/// - permettere la cancellazione del processo.
///
/// NON:
/// - scarica la Flutter SDK;
/// - modifica GitHub;
/// - fa commit/push;
/// - decide se applicare le modifiche;
/// - contiene logica LLM.
///
/// Questo è importante: il provider è solo l'esecutore della toolchain.
final class WorkshopLocalBuildProvider
    implements WorkshopBuildProvider {
  WorkshopLocalBuildProvider({
    required WorkshopLocalBuildConfiguration configuration,
  }) : _configuration = configuration;

  final WorkshopLocalBuildConfiguration _configuration;

  final Map<String, Process> _runningProcesses =
      <String, Process>{};

  final Set<String> _cancelledRequests =
      <String>{};

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.offlineLocal;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) async {
    if (!_targetCanRunHere(target)) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode: executionMode,
        name: 'Flutter local toolchain',
        message:
            'The current platform cannot provide a local '
            '${target.name} Flutter build.',
      );
    }

    final executable =
        File(_configuration.flutterExecutable);

    if (!await executable.exists()) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode: executionMode,
        name: 'Flutter local toolchain',
        path: _configuration.flutterExecutable,
        missingComponents: const <String>[
          'flutter_executable',
        ],
        message:
            'Flutter executable was not found at the configured path.',
      );
    }

    try {
      final result = await Process.run(
        executable.path,
        const <String>[
          '--version',
          '--machine',
        ],
        environment: _configuration.environment,
        runInShell: false,
      ).timeout(_configuration.timeout);

      if (result.exitCode != 0) {
        return WorkshopToolchainInfo(
          target: target,
          status: WorkshopToolchainStatus.invalid,
          executionMode: executionMode,
          name: 'Flutter local toolchain',
          path: executable.path,
          message:
              'Flutter exists but could not be executed.',
        );
      }

      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.available,
        executionMode: executionMode,
        name: 'Flutter local toolchain',
        version: _extractFlutterVersion(
          result.stdout.toString(),
        ),
        path: executable.path,
        message:
            'Flutter local toolchain is executable.',
      );
    } on TimeoutException {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.invalid,
        executionMode: executionMode,
        name: 'Flutter local toolchain',
        path: executable.path,
        message:
            'Flutter toolchain inspection timed out.',
      );
    } catch (error) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.invalid,
        executionMode: executionMode,
        name: 'Flutter local toolchain',
        path: executable.path,
        message: error.toString(),
      );
    }
  }

  @override
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    final startedAt = DateTime.now();

    if (!_targetCanRunHere(request.target)) {
      return _failure(
        request,
        startedAt,
        'Target ${request.target.name} is not supported '
        'by the current local environment.',
        'local_target_not_supported',
      );
    }

    final projectDirectory =
        Directory(request.projectPath);

    if (!await projectDirectory.exists()) {
      return _failure(
        request,
        startedAt,
        'Project directory does not exist: '
        '${request.projectPath}',
        'project_directory_missing',
      );
    }

    final toolchain =
        await inspectToolchain(request.target);

    if (!toolchain.isAvailable) {
      return _failure(
        request,
        startedAt,
        toolchain.message ??
            'Local Flutter toolchain is unavailable.',
        'local_toolchain_unavailable',
      );
    }

    if (_cancelledRequests.contains(request.id)) {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.cancelled,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        message:
            'Local build was cancelled before starting.',
      );
    }

    final steps = <_BuildStep>[
      if (request.runFormatter)
        const _BuildStep(
          name: 'format',
          arguments: <String>[
            'format',
            '--output=none',
            '.',
          ],
        ),
      if (request.runAnalyzer)
        const _BuildStep(
          name: 'analyze',
          arguments: <String>[
            'analyze',
            '--no-pub',
          ],
        ),
      if (request.runTests)
        const _BuildStep(
          name: 'test',
          arguments: <String>[
            'test',
            '--no-pub',
          ],
        ),
      _BuildStep(
        name: 'build',
        arguments: <String>[
          'build',
          _buildTargetArgument(request.target),
          '--no-pub',
          ...request.arguments,
        ],
      ),
    ];

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    bool? formatPassed;
    bool? analysisPassed;
    bool? testsPassed;

    for (final step in steps) {
      if (_cancelledRequests.contains(request.id)) {
        return WorkshopBuildResult(
          requestId: request.id,
          target: request.target,
          status: WorkshopBuildStatus.cancelled,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          stdout: stdoutBuffer.toString(),
          stderr: stderrBuffer.toString(),
          message: 'Local build was cancelled.',
          formatPassed: formatPassed,
          analysisPassed: analysisPassed,
          testsPassed: testsPassed,
        );
      }

      final result = await _runStep(
        request: request,
        step: step,
      );

      stdoutBuffer.write(result.stdout);
      stderrBuffer.write(result.stderr);

      if (step.name == 'format') {
        formatPassed = result.exitCode == 0;
      }

      if (step.name == 'analyze') {
        analysisPassed = result.exitCode == 0;
      }

      if (step.name == 'test') {
        testsPassed = result.exitCode == 0;
      }

      if (result.exitCode != 0) {
        return WorkshopBuildResult(
          requestId: request.id,
          target: request.target,
          status: WorkshopBuildStatus.failed,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          stdout: stdoutBuffer.toString(),
          stderr: stderrBuffer.toString(),
          exitCode: result.exitCode,
          message:
              'Local ${step.name} step failed.',
          errors: <String>[
            'local_${step.name}_failed',
          ],
          formatPassed: formatPassed,
          analysisPassed: analysisPassed,
          testsPassed: testsPassed,
        );
      }
    }

    final artifactPath =
        await _findArtifact(
      request.projectPath,
      request.target,
    );

    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.succeeded,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      artifactPath: artifactPath,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
      exitCode: 0,
      formatPassed: formatPassed,
      analysisPassed: analysisPassed,
      testsPassed: testsPassed,
      message: artifactPath == null
          ? 'Build completed but no artifact was detected.'
          : 'Local Flutter build completed successfully.',
      warnings: artifactPath == null
          ? const <String>[
              'build_artifact_not_detected',
            ]
          : const <String>[],
    );
  }

  @override
  Future<void> cancel(
    String requestId,
  ) async {
    _cancelledRequests.add(requestId);

    final process =
        _runningProcesses[requestId];

    if (process == null) {
      return;
    }

    try {
      process.kill(
        ProcessSignal.sigterm,
      );
    } catch (_) {
      process.kill();
    }
  }

  Future<_ProcessResult> _runStep({
    required WorkshopBuildRequest request,
    required _BuildStep step,
  }) async {
    final environment = <String, String>{
      ...Platform.environment,
      ..._configuration.environment,
      ...request.environment,
    };

    final process = await Process.start(
      _configuration.flutterExecutable,
      step.arguments,
      workingDirectory: request.projectPath,
      environment: environment,
      runInShell: false,
    );

    _runningProcesses[request.id] = process;

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write);

    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write);

    try {
      final exitCode =
          await process.exitCode.timeout(
        _configuration.timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException(
            'Local ${step.name} step timed out.',
          );
        },
      );

      await stdoutSubscription.asFuture<void>();
      await stderrSubscription.asFuture<void>();

      return _ProcessResult(
        exitCode: exitCode,
        stdout: stdoutBuffer.toString(),
        stderr: stderrBuffer.toString(),
      );
    } catch (error) {
      return _ProcessResult(
        exitCode: -1,
        stdout: stdoutBuffer.toString(),
        stderr:
            '${stderrBuffer.toString()}\n$error',
      );
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();

      _runningProcesses.remove(request.id);
    }
  }

  Future<String?> _findArtifact(
    String projectPath,
    WorkshopBuildTarget target,
  ) async {
    final candidates = <String>[];

    switch (target) {
      case WorkshopBuildTarget.android:
        candidates.addAll(<String>[
          '$projectPath/build/app/outputs/'
              'flutter-apk/app-release.apk',
          '$projectPath/build/app/outputs/'
              'flutter-apk/app-debug.apk',
        ]);

      case WorkshopBuildTarget.web:
        candidates.add(
          '$projectPath/build/web',
        );

      case WorkshopBuildTarget.windows:
        candidates.add(
          '$projectPath/build/windows/x64/runner/Release',
        );

      case WorkshopBuildTarget.linux:
        candidates.add(
          '$projectPath/build/linux/x64/release/bundle',
        );

      case WorkshopBuildTarget.macos:
        candidates.add(
          '$projectPath/build/macos/Build/Products/Release',
        );

      case WorkshopBuildTarget.ios:
        candidates.add(
          '$projectPath/build/ios/iphoneos/Runner.app',
        );
    }

    for (final candidate in candidates) {
      final type =
          FileSystemEntity.typeSync(candidate);

      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory) {
        return candidate;
      }
    }

    return null;
  }

  String _buildTargetArgument(
    WorkshopBuildTarget target,
  ) {
    switch (target) {
      case WorkshopBuildTarget.android:
        return 'apk';

      case WorkshopBuildTarget.windows:
        return 'windows';

      case WorkshopBuildTarget.linux:
        return 'linux';

      case WorkshopBuildTarget.macos:
        return 'macos';

      case WorkshopBuildTarget.ios:
        return 'ios';

      case WorkshopBuildTarget.web:
        return 'web';
    }
  }

  bool _targetCanRunHere(
    WorkshopBuildTarget target,
  ) {
    switch (target) {
      case WorkshopBuildTarget.android:
        return true;

      case WorkshopBuildTarget.web:
        return true;

      case WorkshopBuildTarget.windows:
        return Platform.isWindows;

      case WorkshopBuildTarget.linux:
        return Platform.isLinux;

      case WorkshopBuildTarget.macos:
      case WorkshopBuildTarget.ios:
        return Platform.isMacOS;
    }
  }

  String? _extractFlutterVersion(
    String output,
  ) {
    final value = output.trim();

    if (value.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(value);

      if (decoded is Map &&
          decoded['frameworkVersion'] is String) {
        return decoded['frameworkVersion']
            as String;
      }
    } catch (_) {
      // Fallback al testo normale.
    }

    return value
        .split(RegExp(r'\r?\n'))
        .first
        .trim();
  }

  WorkshopBuildResult _failure(
    WorkshopBuildRequest request,
    DateTime startedAt,
    String message,
    String errorCode,
  ) {
    return WorkshopBuildResult(
      requestId: request.id,
      target: request.target,
      status: WorkshopBuildStatus.failed,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      message: message,
      errors: <String>[
        errorCode,
      ],
    );
  }

  Future<void> dispose() async {
    for (final process
        in _runningProcesses.values) {
      try {
        process.kill();
      } catch (_) {}
    }

    _runningProcesses.clear();
    _cancelledRequests.clear();
  }
}

final class _BuildStep {
  const _BuildStep({
    required this.name,
    required this.arguments,
  });

  final String name;
  final List<String> arguments;
}

final class _ProcessResult {
  const _ProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
