import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workshop_build_lab.dart';

/// Configurazione del detector della toolchain locale.
///
/// Il detector non installa nulla e non scarica nulla.
/// Controlla solamente ciò che è già disponibile.
final class WorkshopLocalToolchainDetectorConfiguration {
  const WorkshopLocalToolchainDetectorConfiguration({
    this.flutterExecutable = 'flutter',
    this.javaExecutable = 'java',
    this.androidSdkPath,
    this.environment = const <String, String>{},
    this.timeout = const Duration(seconds: 15),
  });

  final String flutterExecutable;
  final String javaExecutable;
  final String? androidSdkPath;
  final Map<String, String> environment;
  final Duration timeout;
}

/// Risultato completo dell'ispezione.
final class WorkshopLocalToolchainReport {
  const WorkshopLocalToolchainReport({
    required this.checkedAt,
    required this.flutterAvailable,
    required this.dartAvailable,
    required this.javaAvailable,
    required this.androidSdkAvailable,
    required this.offlineCapable,
    required this.targets,
    this.flutterVersion,
    this.dartVersion,
    this.javaVersion,
    this.androidSdkPath,
    this.message,
  });

  final DateTime checkedAt;

  final bool flutterAvailable;
  final bool dartAvailable;
  final bool javaAvailable;
  final bool androidSdkAvailable;

  final bool offlineCapable;

  final Map<WorkshopBuildTarget, WorkshopToolchainInfo> targets;

  final String? flutterVersion;
  final String? dartVersion;
  final String? javaVersion;
  final String? androidSdkPath;

  final String? message;

  WorkshopToolchainInfo? infoFor(
    WorkshopBuildTarget target,
  ) {
    return targets[target];
  }

  bool canBuildOffline(
    WorkshopBuildTarget target,
  ) {
    return targets[target]?.canBuildOffline ?? false;
  }
}

/// Analizza la toolchain locale senza modificarla.
///
/// Responsabilità:
/// - verificare Flutter;
/// - verificare Dart;
/// - verificare Java;
/// - verificare Android SDK;
/// - determinare quali target possono essere gestiti localmente.
///
/// Non installa SDK.
/// Non scarica file.
/// Non esegue build.
final class WorkshopLocalToolchainDetector {
  WorkshopLocalToolchainDetector({
    WorkshopLocalToolchainDetectorConfiguration configuration =
        const WorkshopLocalToolchainDetectorConfiguration(),
  }) : _configuration = configuration;

  final WorkshopLocalToolchainDetectorConfiguration _configuration;

  bool _disposed = false;

  Future<WorkshopLocalToolchainReport> inspectAll() async {
    _ensureAvailable();

    final checks = await Future.wait<_ToolchainCheck>(
      <Future<_ToolchainCheck>>[
        _checkFlutter().then(
          (value) => _ToolchainCheck.flutter(value),
        ),
        _checkDart().then(
          (value) => _ToolchainCheck.dart(value),
        ),
        _checkJava().then(
          (value) => _ToolchainCheck.java(value),
        ),
        _checkAndroidSdk().then(
          (value) => _ToolchainCheck.android(value),
        ),
      ],
    );

    _ensureAvailable();

    final flutter = checks
        .firstWhere(
          (check) => check.flutter != null,
        )
        .flutter!;

    final dart = checks
        .firstWhere(
          (check) => check.dart != null,
        )
        .dart!;

    final java = checks
        .firstWhere(
          (check) => check.java != null,
        )
        .java!;

    final android = checks
        .firstWhere(
          (check) => check.android != null,
        )
        .android!;

    final targets =
        <WorkshopBuildTarget, WorkshopToolchainInfo>{};

    for (final target in WorkshopBuildTarget.values) {
      targets[target] = _buildTargetInfo(
        target: target,
        flutter: flutter,
        dart: dart,
        java: java,
        android: android,
      );
    }

    final offlineCapable = targets.values.any(
      (info) => info.canBuildOffline,
    );

    return WorkshopLocalToolchainReport(
      checkedAt: DateTime.now().toUtc(),
      flutterAvailable: flutter.available,
      dartAvailable: dart.available,
      javaAvailable: java.available,
      androidSdkAvailable: android.available,
      offlineCapable: offlineCapable,
      targets: Map.unmodifiable(targets),
      flutterVersion: flutter.version,
      dartVersion: dart.version,
      javaVersion: java.version,
      androidSdkPath: android.path,
      message: _buildReportMessage(
        flutter: flutter,
        dart: dart,
        java: java,
        android: android,
      ),
    );
  }

  Future<WorkshopToolchainInfo> inspectTarget(
    WorkshopBuildTarget target,
  ) async {
    _ensureAvailable();

    final checks = await Future.wait<_ToolchainCheck>(
      <Future<_ToolchainCheck>>[
        _checkFlutter().then(
          (value) => _ToolchainCheck.flutter(value),
        ),
        _checkDart().then(
          (value) => _ToolchainCheck.dart(value),
        ),
        _checkJava().then(
          (value) => _ToolchainCheck.java(value),
        ),
        _checkAndroidSdk().then(
          (value) => _ToolchainCheck.android(value),
        ),
      ],
    );

    _ensureAvailable();

    final flutter = checks
        .firstWhere(
          (check) => check.flutter != null,
        )
        .flutter!;

    final dart = checks
        .firstWhere(
          (check) => check.dart != null,
        )
        .dart!;

    final java = checks
        .firstWhere(
          (check) => check.java != null,
        )
        .java!;

    final android = checks
        .firstWhere(
          (check) => check.android != null,
        )
        .android!;

    return _buildTargetInfo(
      target: target,
      flutter: flutter,
      dart: dart,
      java: java,
      android: android,
    );
  }

  Future<_CommandCheck> _checkFlutter() async {
    final result = await _run(
      _configuration.flutterExecutable,
      const <String>[
        '--version',
        '--machine',
      ],
    );

    if (!result.success) {
      return _CommandCheck.unavailable(
        message: result.message,
      );
    }

    String? version;

    try {
      final decoded = jsonDecode(result.stdout);

      if (decoded is Map &&
          decoded['frameworkVersion'] is String) {
        version = decoded['frameworkVersion'] as String;
      }
    } catch (_) {
      version = _firstLine(result.stdout);
    }

    return _CommandCheck(
      available: true,
      version: version,
      output: result.stdout,
    );
  }

  Future<_CommandCheck> _checkDart() async {
    final result = await _run(
      _configuration.flutterExecutable,
      const <String>[
        'dart',
        '--version',
      ],
    );

    if (!result.success) {
      return _CommandCheck.unavailable(
        message: result.message,
      );
    }

    final output =
        result.stderr.isNotEmpty
            ? result.stderr
            : result.stdout;

    return _CommandCheck(
      available: true,
      version: _firstLine(output),
      output: output,
    );
  }

  Future<_CommandCheck> _checkJava() async {
    final result = await _run(
      _configuration.javaExecutable,
      const <String>[
        '-version',
      ],
    );

    if (!result.success) {
      return _CommandCheck.unavailable(
        message: result.message,
      );
    }

    final output =
        result.stderr.isNotEmpty
            ? result.stderr
            : result.stdout;

    return _CommandCheck(
      available: true,
      version: _firstLine(output),
      output: output,
    );
  }

  Future<_AndroidCheck> _checkAndroidSdk() async {
    final sdkPath = _findAndroidSdkPath();

    if (sdkPath == null) {
      return const _AndroidCheck(
        available: false,
        path: null,
        platformTools: false,
        buildTools: false,
        platforms: false,
      );
    }

    final results = await Future.wait<bool>(
      <Future<bool>>[
        Directory(
          _join(sdkPath, 'platform-tools'),
        ).exists(),
        _hasDirectory(
          _join(sdkPath, 'build-tools'),
        ),
        _hasDirectory(
          _join(sdkPath, 'platforms'),
        ),
      ],
    );

    final platformTools = results[0];
    final buildTools = results[1];
    final platforms = results[2];

    return _AndroidCheck(
      available:
          platformTools &&
          buildTools &&
          platforms,
      path: sdkPath,
      platformTools: platformTools,
      buildTools: buildTools,
      platforms: platforms,
    );
  }

  String? _findAndroidSdkPath() {
    final configured =
        _configuration.androidSdkPath;

    if (configured != null &&
        configured.trim().isNotEmpty &&
        Directory(configured).existsSync()) {
      return configured;
    }

    final configuredRoot =
        _configuration.environment['ANDROID_SDK_ROOT'];

    if (configuredRoot != null &&
        configuredRoot.isNotEmpty &&
        Directory(configuredRoot).existsSync()) {
      return configuredRoot;
    }

    final configuredHome =
        _configuration.environment['ANDROID_HOME'];

    if (configuredHome != null &&
        configuredHome.isNotEmpty &&
        Directory(configuredHome).existsSync()) {
      return configuredHome;
    }

    final root =
        Platform.environment['ANDROID_SDK_ROOT'];

    if (root != null &&
        root.isNotEmpty &&
        Directory(root).existsSync()) {
      return root;
    }

    final home =
        Platform.environment['ANDROID_HOME'];

    if (home != null &&
        home.isNotEmpty &&
        Directory(home).existsSync()) {
      return home;
    }

    final candidates =
        _standardAndroidSdkPaths();

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    return null;
  }

  List<String> _standardAndroidSdkPaths() {
    final home =
        Platform.environment['HOME'];

    if (home == null || home.isEmpty) {
      return const <String>[];
    }

    if (Platform.isMacOS || Platform.isLinux) {
      return <String>[
        _join(home, 'Android/Sdk'),
        _join(home, 'android-sdk'),
      ];
    }

    return const <String>[];
  }

  WorkshopToolchainInfo _buildTargetInfo({
    required WorkshopBuildTarget target,
    required _CommandCheck flutter,
    required _CommandCheck dart,
    required _CommandCheck java,
    required _AndroidCheck android,
  }) {
    if (!flutter.available) {
      return _unavailable(
        target: target,
        missing: const <String>[
          'flutter',
        ],
        message:
            'Flutter is not available on this host.',
      );
    }

    if (!dart.available) {
      return _incomplete(
        target: target,
        version: flutter.version,
        missing: const <String>[
          'dart',
        ],
        message:
            'Flutter is available but Dart could not be verified.',
      );
    }

    switch (target) {
      case WorkshopBuildTarget.android:
        return _androidInfo(
          flutter: flutter,
          java: java,
          android: android,
        );

      case WorkshopBuildTarget.web:
        return _hostTargetInfo(
          target: target,
          name: 'Flutter Web',
          available: _flutterHostAvailable(),
          missing: const <String>[
            'flutter_execution_host',
          ],
        );

      case WorkshopBuildTarget.windows:
        return _hostTargetInfo(
          target: target,
          name: 'Flutter Windows',
          available:
              Platform.isWindows &&
              _flutterHostAvailable(),
          missing: const <String>[
            'windows_build_host',
          ],
        );

      case WorkshopBuildTarget.linux:
        return _hostTargetInfo(
          target: target,
          name: 'Flutter Linux',
          available:
              Platform.isLinux &&
              _flutterHostAvailable(),
          missing: const <String>[
            'linux_build_host',
          ],
        );

      case WorkshopBuildTarget.macos:
        return _hostTargetInfo(
          target: target,
          name: 'Flutter macOS',
          available:
              Platform.isMacOS &&
              _flutterHostAvailable(),
          missing: const <String>[
            'macos_build_host',
          ],
        );

      case WorkshopBuildTarget.ios:
        return _hostTargetInfo(
          target: target,
          name: 'Flutter iOS',
          available:
              Platform.isMacOS &&
              _flutterHostAvailable(),
          missing: const <String>[
            'ios_macos_build_host',
          ],
        );
    }
  }

  WorkshopToolchainInfo _androidInfo({
    required _CommandCheck flutter,
    required _CommandCheck java,
    required _AndroidCheck android,
  }) {
    final missing = <String>[];

    if (!java.available) {
      missing.add('java');
    }

    if (!android.platformTools) {
      missing.add('android_platform_tools');
    }

    if (!android.buildTools) {
      missing.add('android_build_tools');
    }

    if (!android.platforms) {
      missing.add('android_platforms');
    }

    final hostAvailable =
        _androidHostAvailable();

    if (!hostAvailable) {
      missing.add('android_build_host');
    }

    final available =
        missing.isEmpty;

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.android,
      status:
          available
              ? WorkshopToolchainStatus.available
              : WorkshopToolchainStatus.incomplete,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter Android local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents:
          List.unmodifiable(missing),
      message:
          available
              ? 'Android local build environment is available.'
              : 'Android local build environment is incomplete.',
    );
  }

  WorkshopToolchainInfo _hostTargetInfo({
    required WorkshopBuildTarget target,
    required String name,
    required bool available,
    required List<String> missing,
  }) {
    return WorkshopToolchainInfo(
      target: target,
      status:
          available
              ? WorkshopToolchainStatus.available
              : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: name,
      path: _configuration.flutterExecutable,
      missingComponents:
          available
              ? const <String>[]
              : missing,
      message:
          available
              ? '$name can be handled locally.'
              : '$name requires a compatible build host.',
    );
  }

  WorkshopToolchainInfo _unavailable({
    required WorkshopBuildTarget target,
    required List<String> missing,
    required String message,
  }) {
    return WorkshopToolchainInfo(
      target: target,
      status:
          WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter local toolchain',
      path: _configuration.flutterExecutable,
      missingComponents: missing,
      message: message,
    );
  }

  WorkshopToolchainInfo _incomplete({
    required WorkshopBuildTarget target,
    required String? version,
    required List<String> missing,
    required String message,
  }) {
    return WorkshopToolchainInfo(
      target: target,
      status:
          WorkshopToolchainStatus.incomplete,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter local toolchain',
      version: version,
      path: _configuration.flutterExecutable,
      missingComponents: missing,
      message: message,
    );
  }

  bool _flutterHostAvailable() {
    // Su Android non dichiariamo una toolchain Flutter
    // eseguibile solo perché esiste un file "flutter".
    return !Platform.isAndroid;
  }

  bool _androidHostAvailable() {
    // Il detector è conservativo:
    // Android SDK + Java devono essere eseguibili
    // su un host compatibile.
    return Platform.isLinux ||
        Platform.isWindows ||
        Platform.isMacOS;
  }

  String _buildReportMessage({
    required _CommandCheck flutter,
    required _CommandCheck dart,
    required _CommandCheck java,
    required _AndroidCheck android,
  }) {
    if (!flutter.available) {
      return 'Flutter is not available.';
    }

    if (!dart.available) {
      return 'Dart could not be verified.';
    }

    if (!java.available) {
      return 'Java is not available.';
    }

    if (!android.available) {
      return 'Flutter is available but Android SDK is incomplete.';
    }

    return 'Local toolchain inspection completed.';
  }

  Future<_CommandResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final environment =
          <String, String>{
        ...Platform.environment,
        ..._configuration.environment,
      };

      final process =
          await Process.start(
        executable,
        arguments,
        environment: environment,
        runInShell: Platform.isWindows,
      );

      final stdoutFuture =
          process.stdout
              .transform(utf8.decoder)
              .join();

      final stderrFuture =
          process.stderr
              .transform(utf8.decoder)
              .join();

      final exitCode =
          await process.exitCode.timeout(
        _configuration.timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException(
            'Command timed out: $executable',
          );
        },
      );

      final stdout =
          await stdoutFuture;

      final stderr =
          await stderrFuture;

      return _CommandResult(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
      );
    } on TimeoutException catch (error) {
      return _CommandResult(
        exitCode: -1,
        message: error.toString(),
      );
    } on ProcessException catch (error) {
      return _CommandResult(
        exitCode: -1,
        message: error.message,
      );
    } catch (error) {
      return _CommandResult(
        exitCode: -1,
        message: error.toString(),
      );
    }
  }

  Future<bool> _hasDirectory(
    String path,
  ) async {
    final directory = Directory(path);

    if (!await directory.exists()) {
      return false;
    }

    await for (final entity
        in directory.list()) {
      if (entity is Directory) {
        return true;
      }
    }

    return false;
  }

  String _join(
    String first,
    String second,
  ) {
    final separator =
        Platform.pathSeparator;

    final left =
        first.endsWith(separator)
            ? first.substring(
                0,
                first.length - 1,
              )
            : first;

    final right =
        second.startsWith(separator)
            ? second.substring(1)
            : second;

    return '$left$separator$right';
  }

  String? _firstLine(
    String value,
  ) {
    for (final line
        in value.split(RegExp(r'\r?\n'))) {
      final result =
          line.trim();

      if (result.isNotEmpty) {
        return result;
      }
    }

    return null;
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopLocalToolchainDetector '
        'has been disposed.',
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
  }
}

final class _ToolchainCheck {
  const _ToolchainCheck.flutter(
    _CommandCheck value,
  ) : flutter = value,
       dart = null,
       java = null,
       android = null;

  const _ToolchainCheck.dart(
    _CommandCheck value,
  ) : flutter = null,
       dart = value,
       java = null,
       android = null;

  const _ToolchainCheck.java(
    _CommandCheck value,
  ) : flutter = null,
       dart = null,
       java = value,
       android = null;

  const _ToolchainCheck.android(
    _AndroidCheck value,
  ) : flutter = null,
       dart = null,
       java = null,
       android = value;

  final _CommandCheck? flutter;
  final _CommandCheck? dart;
  final _CommandCheck? java;
  final _AndroidCheck? android;
}

final class _CommandCheck {
  const _CommandCheck({
    required this.available,
    this.version,
    this.output = '',
  }) : message = null;

  const _CommandCheck.unavailable({
    this.message,
  })  : available = false,
        version = null,
        output = '';

  final bool available;
  final String? version;
  final String output;
  final String? message;
}

final class _CommandResult {
  const _CommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.message,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final String? message;

  bool get success => exitCode == 0;
}

final class _AndroidCheck {
  const _AndroidCheck({
    required this.available,
    required this.path,
    required this.platformTools,
    required this.buildTools,
    required this.platforms,
  });

  final bool available;
  final String? path;
  final bool platformTools;
  final bool buildTools;
  final bool platforms;
}
