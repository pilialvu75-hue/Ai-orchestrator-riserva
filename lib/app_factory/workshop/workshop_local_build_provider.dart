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
    this.dartExecutable,
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

  /// Optional Dart executable. When omitted, the provider first looks for the
  /// Dart binary next to Flutter and then falls back to PATH.
  final String? dartExecutable;

  final Map<String, String> environment;

  final Duration timeout;
}

enum WorkshopLocalBuildExecutable {
  flutter,
  dart,
}

final class WorkshopLocalBuildStep {
  const WorkshopLocalBuildStep({
    required this.name,
    required this.executable,
    required this.arguments,
  });

  final String name;
  final WorkshopLocalBuildExecutable executable;
  final List<String> arguments;
}

/// Deterministic command plan for a local/offline Flutter build.
///
/// Dependency resolution is always explicit and offline. A clean build runs
/// before dependency resolution because `flutter clean` removes generated
/// package metadata.
abstract final class WorkshopLocalBuildPlanner {
  static List<WorkshopLocalBuildStep> plan(WorkshopBuildRequest request) {
    return <WorkshopLocalBuildStep>[
      if (request.cleanBuild)
        const WorkshopLocalBuildStep(
          name: 'clean',
          executable: WorkshopLocalBuildExecutable.flutter,
          arguments: <String>['clean'],
        ),
      const WorkshopLocalBuildStep(
        name: 'pub_get_offline',
        executable: WorkshopLocalBuildExecutable.flutter,
        arguments: <String>['pub', 'get', '--offline'],
      ),
      if (request.runFormatter)
        const WorkshopLocalBuildStep(
          name: 'format',
          executable: WorkshopLocalBuildExecutable.dart,
          arguments: <String>[
            'format',
            '--output=none',
            '--set-exit-if-changed',
            '.',
          ],
        ),
      if (request.runAnalyzer)
        const WorkshopLocalBuildStep(
          name: 'analyze',
          executable: WorkshopLocalBuildExecutable.flutter,
          arguments: <String>['analyze', '--no-pub'],
        ),
      if (request.runTests)
        const WorkshopLocalBuildStep(
          name: 'test',
          executable: WorkshopLocalBuildExecutable.flutter,
          arguments: <String>['test', '--no-pub'],
        ),
      WorkshopLocalBuildStep(
        name: 'build',
        executable: WorkshopLocalBuildExecutable.flutter,
        arguments: <String>[
          'build',
          _buildTargetArgument(request.target),
          '--no-pub',
          ...request.arguments,
        ],
      ),
    ];
  }

  static String _buildTargetArgument(WorkshopBuildTarget target) {
    return switch (target) {
      WorkshopBuildTarget.android => 'apk',
      WorkshopBuildTarget.windows => 'windows',
      WorkshopBuildTarget.linux => 'linux',
      WorkshopBuildTarget.macos => 'macos',
      WorkshopBuildTarget.ios => 'ios',
      WorkshopBuildTarget.web => 'web',
    };
  }
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

    final steps = WorkshopLocalBuildPlanner.plan(request);

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

      stdoutBuffer.writeln(
        '[WORKSHOP_LOCAL_BUILD_STEP] begin=${step.name} '
        'executor=${step.executable.name}',
      );
      final result = await _runStep(
        request: request,
        step: step,
      );
      stdoutBuffer.write(result.stdout);
      stderrBuffer.write(result.stderr);
      stdoutBuffer.writeln(
        '[WORKSHOP_LOCAL_BUILD_STEP] end=${step.name} '
        'exit_code=${result.exitCode}',
      );

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

    if (artifactPath == null) {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        stdout: stdoutBuffer.toString(),
        stderr: stderrBuffer.toString(),
        exitCode: 0,
        formatPassed: formatPassed,
        analysisPassed: analysisPassed,
        testsPassed: testsPassed,
        message: 'Build command completed but no artifact was detected.',
        errors: const <String>['build_artifact_not_detected'],
      );
    }

    stdoutBuffer.writeln(
      '[WORKSHOP_LOCAL_BUILD_ARTIFACT] path=$artifactPath',
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
      message: 'Local Flutter build completed successfully.',
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
    required WorkshopLocalBuildStep step,
  }) async {
    final environment = <String, String>{
      ...Platform.environment,
      ..._configuration.environment,
      ...request.environment,
    };

    final executable = step.executable == WorkshopLocalBuildExecutable.dart
        ? _resolveDartExecutable()
        : _configuration.flutterExecutable;

    final process = await Process.start(
      executable,
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

  String _resolveDartExecutable() {
    final configured = _configuration.dartExecutable?.trim();
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }

    final flutterExecutable = _configuration.flutterExecutable.trim();
    final flutterFile = File(flutterExecutable);
    final hasExplicitPath = flutterFile.isAbsolute ||
        flutterExecutable.contains(Platform.pathSeparator);
    if (hasExplicitPath) {
      final siblingName = Platform.isWindows ? 'dart.bat' : 'dart';
      final sibling = File(
        '${flutterFile.parent.path}${Platform.pathSeparator}$siblingName',
      );
      if (sibling.existsSync()) {
        return sibling.path;
      }
    }

    return 'dart';
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
