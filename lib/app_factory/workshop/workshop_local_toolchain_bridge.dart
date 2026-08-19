import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Tipo di comando della toolchain locale.
///
/// Il bridge espone solo comandi esplicitamente conosciuti.
/// Non accetta una shell command arbitraria.
enum WorkshopLocalToolchainCommand {
  dartAnalyze,
  dartTest,
  flutterAnalyze,
  flutterTest,
  flutterBuildApk,
  flutterBuildAppBundle,
  flutterBuildWindows,
  flutterBuildLinux,
  flutterBuildMacos,
  flutterPubGet,
  flutterPubGetOffline,
}

/// Risultato di un comando della toolchain locale.
final class WorkshopLocalToolchainResult {
  const WorkshopLocalToolchainResult({
    required this.command,
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
    required this.startedAt,
    required this.finishedAt,
    this.timedOut = false,
    this.cancelled = false,
    this.metadata = const <String, dynamic>{},
  });

  final WorkshopLocalToolchainCommand command;
  final String executable;
  final List<String> arguments;

  final int exitCode;

  final String stdout;
  final String stderr;

  final Duration duration;

  final DateTime startedAt;
  final DateTime finishedAt;

  final bool timedOut;
  final bool cancelled;

  final Map<String, dynamic> metadata;

  bool get succeeded =>
      !timedOut &&
      !cancelled &&
      exitCode == 0;

  bool get failed => !succeeded;

  String get combinedOutput {
    final buffer = StringBuffer();

    if (stdout.trim().isNotEmpty) {
      buffer.writeln(stdout.trim());
    }

    if (stderr.trim().isNotEmpty) {
      buffer.writeln(stderr.trim());
    }

    return buffer.toString().trim();
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'command': command.name,
      'executable': executable,
      'arguments': List<String>.unmodifiable(arguments),
      'exitCode': exitCode,
      'stdout': stdout,
      'stderr': stderr,
      'durationMs': duration.inMilliseconds,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'finishedAt': finishedAt.toUtc().toIso8601String(),
      'timedOut': timedOut,
      'cancelled': cancelled,
      'metadata': Map<String, dynamic>.unmodifiable(
        metadata,
      ),
    };
  }
}

/// Configurazione del Local Toolchain Bridge.
final class WorkshopLocalToolchainConfig {
  const WorkshopLocalToolchainConfig({
    this.defaultTimeout = const Duration(minutes: 10),
    this.buildTimeout = const Duration(minutes: 20),
    this.allowNetwork = false,
    this.allowPubGet = false,
    this.allowBuilds = true,
    this.maxOutputCharacters = 200000,
  });

  /// Timeout normale per analyze/test.
  final Duration defaultTimeout;

  /// Timeout più ampio per le build.
  final Duration buildTimeout;

  /// Se false, il bridge non abilita deliberatamente
  /// operazioni che richiedono rete.
  final bool allowNetwork;

  /// `pub get` normale può richiedere rete.
  ///
  /// Rimane false per default.
  final bool allowPubGet;

  /// Abilita i comandi di build.
  final bool allowBuilds;

  /// Limite massimo del testo restituito.
  final int maxOutputCharacters;
}

/// Bridge sicuro verso Dart/Flutter locali.
///
/// Il bridge:
///
/// - non sceglie LOCAL/HYBRID/CLOUD;
/// - non chiama provider AI;
/// - non modifica il repository autonomamente;
/// - non usa una shell arbitraria;
/// - esegue soltanto comandi presenti nell'enum;
/// - lavora nella directory indicata dal chiamante;
/// - permette timeout;
/// - può essere usato anche offline.
///
/// La decisione se una task possa usare questo bridge
/// appartiene al livello superiore del Workshop.
final class WorkshopLocalToolchainBridge {
  WorkshopLocalToolchainBridge({
    WorkshopLocalToolchainConfig config =
        const WorkshopLocalToolchainConfig(),
  }) : config = config;

  final WorkshopLocalToolchainConfig config;

  Process? _activeProcess;
  bool _cancelRequested = false;

  bool get isRunning => _activeProcess != null;

  /// Esegue un comando esplicitamente autorizzato.
  Future<WorkshopLocalToolchainResult> execute({
    required WorkshopLocalToolchainCommand command,
    required String workingDirectory,
    List<String> extraArguments = const <String>[],
    Duration? timeout,
    bool? allowNetwork,
  }) async {
    if (isRunning) {
      throw StateError(
        'Another local toolchain command is already running.',
      );
    }

    final directory = Directory(workingDirectory);

    if (!await directory.exists()) {
      throw ArgumentError.value(
        workingDirectory,
        'workingDirectory',
        'Working directory does not exist.',
      );
    }

    final specification = _specificationFor(
      command,
      extraArguments,
    );

    _validateCommand(
      command,
      specification,
      allowNetwork:
          allowNetwork ?? config.allowNetwork,
    );

    final startedAt = DateTime.now().toUtc();

    _cancelRequested = false;

    Process? process;

    try {
      process = await Process.start(
        specification.executable,
        specification.arguments,
        workingDirectory: directory.path,
        runInShell: false,
        includeParentEnvironment: true,
      );

      _activeProcess = process;

      final stdoutFuture = process.stdout
          .transform(utf8.decoder)
          .join();

      final stderrFuture = process.stderr
          .transform(utf8.decoder)
          .join();

      final exitCodeFuture = process.exitCode;

      final effectiveTimeout =
          timeout ?? _timeoutFor(command);

      final exitCode = await exitCodeFuture.timeout(
        effectiveTimeout,
        onTimeout: () async {
          await _killProcess(process!);

          throw TimeoutException(
            'Local toolchain command timed out.',
            effectiveTimeout,
          );
        },
      );

      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;

      final finishedAt = DateTime.now().toUtc();

      final cancelled = _cancelRequested;

      return WorkshopLocalToolchainResult(
        command: command,
        executable: specification.executable,
        arguments: specification.arguments,
        exitCode: exitCode,
        stdout: _limitOutput(stdout),
        stderr: _limitOutput(stderr),
        duration: finishedAt.difference(startedAt),
        startedAt: startedAt,
        finishedAt: finishedAt,
        cancelled: cancelled,
        metadata: <String, dynamic>{
          'workingDirectory': directory.path,
          'offline':
              !(allowNetwork ?? config.allowNetwork),
        },
      );
    } on TimeoutException {
      final finishedAt = DateTime.now().toUtc();

      return WorkshopLocalToolchainResult(
        command: command,
        executable: specification.executable,
        arguments: specification.arguments,
        exitCode: -1,
        stdout: '',
        stderr: 'Local toolchain command timed out.',
        duration: finishedAt.difference(startedAt),
        startedAt: startedAt,
        finishedAt: finishedAt,
        timedOut: true,
        metadata: <String, dynamic>{
          'workingDirectory': directory.path,
        },
      );
    } on ProcessException catch (error) {
      final finishedAt = DateTime.now().toUtc();

      return WorkshopLocalToolchainResult(
        command: command,
        executable: specification.executable,
        arguments: specification.arguments,
        exitCode: error.errorCode,
        stdout: '',
        stderr: error.message,
        duration: finishedAt.difference(startedAt),
        startedAt: startedAt,
        finishedAt: finishedAt,
        cancelled: _cancelRequested,
        metadata: <String, dynamic>{
          'workingDirectory': directory.path,
        },
      );
    } catch (error) {
      final finishedAt = DateTime.now().toUtc();

      return WorkshopLocalToolchainResult(
        command: command,
        executable: specification.executable,
        arguments: specification.arguments,
        exitCode: -1,
        stdout: '',
        stderr: error.toString(),
        duration: finishedAt.difference(startedAt),
        startedAt: startedAt,
        finishedAt: finishedAt,
        cancelled: _cancelRequested,
        metadata: <String, dynamic>{
          'workingDirectory': directory.path,
        },
      );
    } finally {
      _activeProcess = null;
      _cancelRequested = false;
    }
  }

  /// Interrompe il comando locale attualmente in esecuzione.
  Future<bool> cancel() async {
    final process = _activeProcess;

    if (process == null) {
      return false;
    }

    _cancelRequested = true;

    await _killProcess(process);

    return true;
  }

  Future<void> _killProcess(
    Process process,
  ) async {
    try {
      process.kill(ProcessSignal.sigterm);

      await Future<void>.delayed(
        const Duration(milliseconds: 250),
      );

      if (identical(_activeProcess, process)) {
        process.kill(ProcessSignal.sigkill);
      }
    } catch (_) {
      // Il processo potrebbe essere già terminato.
    }
  }

  Duration _timeoutFor(
    WorkshopLocalToolchainCommand command,
  ) {
    switch (command) {
      case WorkshopLocalToolchainCommand.flutterBuildApk:
      case WorkshopLocalToolchainCommand.flutterBuildAppBundle:
      case WorkshopLocalToolchainCommand.flutterBuildWindows:
      case WorkshopLocalToolchainCommand.flutterBuildLinux:
      case WorkshopLocalToolchainCommand.flutterBuildMacos:
        return config.buildTimeout;

      default:
        return config.defaultTimeout;
    }
  }

  _ToolchainSpecification _specificationFor(
    WorkshopLocalToolchainCommand command,
    List<String> extraArguments,
  ) {
    switch (command) {
      case WorkshopLocalToolchainCommand.dartAnalyze:
        return _ToolchainSpecification(
          executable: 'dart',
          arguments: <String>[
            'analyze',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.dartTest:
        return _ToolchainSpecification(
          executable: 'dart',
          arguments: <String>[
            'test',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterAnalyze:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'analyze',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterTest:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'test',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterBuildApk:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'build',
            'apk',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterBuildAppBundle:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'build',
            'appbundle',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterBuildWindows:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'build',
            'windows',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterBuildLinux:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'build',
            'linux',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterBuildMacos:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'build',
            'macos',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterPubGet:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'pub',
            'get',
            ...extraArguments,
          ],
        );

      case WorkshopLocalToolchainCommand.flutterPubGetOffline:
        return _ToolchainSpecification(
          executable: 'flutter',
          arguments: <String>[
            'pub',
            'get',
            '--offline',
            ...extraArguments,
          ],
        );
    }
  }

  void _validateCommand(
    WorkshopLocalToolchainCommand command,
    _ToolchainSpecification specification, {
    required bool allowNetwork,
  }) {
    if (!config.allowBuilds &&
        _isBuildCommand(command)) {
      throw StateError(
        'Local builds are disabled by configuration.',
      );
    }

    if (command ==
            WorkshopLocalToolchainCommand.flutterPubGet &&
        !config.allowPubGet) {
      throw StateError(
        'Normal pub get is disabled. '
        'Use flutterPubGetOffline or explicitly enable pub get.',
      );
    }

    if (!allowNetwork &&
        command ==
            WorkshopLocalToolchainCommand.flutterPubGet) {
      throw StateError(
        'Network access is disabled for the local toolchain.',
      );
    }

    if (specification.executable != 'dart' &&
        specification.executable != 'flutter') {
      throw StateError(
        'Executable is not allowed by the local toolchain policy.',
      );
    }

    if (_containsShellControlCharacters(
      specification.arguments,
    )) {
      throw ArgumentError(
        'Toolchain arguments contain forbidden shell control characters.',
      );
    }
  }

  bool _isBuildCommand(
    WorkshopLocalToolchainCommand command,
  ) {
    switch (command) {
      case WorkshopLocalToolchainCommand.flutterBuildApk:
      case WorkshopLocalToolchainCommand.flutterBuildAppBundle:
      case WorkshopLocalToolchainCommand.flutterBuildWindows:
      case WorkshopLocalToolchainCommand.flutterBuildLinux:
      case WorkshopLocalToolchainCommand.flutterBuildMacos:
        return true;

      default:
        return false;
    }
  }

  bool _containsShellControlCharacters(
    List<String> arguments,
  ) {
    const forbidden = <String>[
      ';',
      '&&',
      '||',
      '|',
      '>',
      '<',
      '`',
      r'$(',
    ];

    for (final argument in arguments) {
      for (final token in forbidden) {
        if (argument.contains(token)) {
          return true;
        }
      }
    }

    return false;
  }

  String _limitOutput(
    String value,
  ) {
    if (value.length <= config.maxOutputCharacters) {
      return value;
    }

    return '${value.substring(0, config.maxOutputCharacters)}\n'
        '[output truncated]';
  }
}

final class _ToolchainSpecification {
  const _ToolchainSpecification({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}
