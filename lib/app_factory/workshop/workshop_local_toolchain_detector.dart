import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workshop_build_lab.dart';

/// Configurazione del rilevatore della toolchain locale.
final class WorkshopLocalToolchainDetectorConfiguration {
  const WorkshopLocalToolchainDetectorConfiguration({
    required this.flutterExecutable,
    this.javaExecutable = 'java',
    this.gradleExecutable = 'gradle',
    this.androidSdkPath,
    this.androidSdkManagerExecutable,
    this.timeout = const Duration(seconds: 20),
    this.environment = const <String, String>{},
  });

  /// Percorso dell'eseguibile Flutter.
  ///
  /// Può essere:
  /// - flutter
  /// - flutter.bat
  /// - percorso assoluto della Flutter SDK.
  final String flutterExecutable;

  final String javaExecutable;
  final String gradleExecutable;

  /// Percorso esplicito dell'Android SDK.
  ///
  /// Se nullo vengono controllati:
  /// ANDROID_SDK_ROOT
  /// ANDROID_HOME
  /// percorsi standard della piattaforma.
  final String? androidSdkPath;

  final String? androidSdkManagerExecutable;

  final Duration timeout;

  final Map<String, String> environment;
}

/// Risultato complessivo dell'ispezione.
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

  /// Indica se almeno un target locale può essere costruito offline.
  final bool offlineCapable;

  final Map<WorkshopBuildTarget, WorkshopToolchainInfo>
      targets;

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

/// Rilevatore della toolchain disponibile sul dispositivo.
///
/// IMPORTANTE:
/// questo componente NON installa SDK e NON scarica nulla.
///
/// Il suo unico compito è rispondere alla domanda:
///
/// "Con ciò che è realmente installato adesso,
///  cosa posso costruire localmente e offline?"
///
/// In questo modo il futuro ToolchainManager potrà installare
/// solamente ciò che manca.
final class WorkshopLocalToolchainDetector {
  WorkshopLocalToolchainDetector({
    required WorkshopLocalToolchainDetectorConfiguration
        configuration,
  }) : _configuration = configuration;

  final WorkshopLocalToolchainDetectorConfiguration
      _configuration;

  bool _disposed = false;

  Future<WorkshopLocalToolchainReport> inspectAll() async {
    _ensureAvailable();

    final checkedAt = DateTime.now();

    final flutter = await _inspectFlutter();
    final dart = await _inspectDart();
    final java = await _inspectJava();

    final androidSdk =
        await _inspectAndroidSdk();

    final targets =
        <WorkshopBuildTarget, WorkshopToolchainInfo>{};

    for (final target in WorkshopBuildTarget.values) {
      targets[target] = await _inspectTarget(
        target: target,
        flutter: flutter,
        dart: dart,
        java: java,
        androidSdk: androidSdk,
      );
    }

    final offlineCapable = targets.values.any(
      (info) => info.canBuildOffline,
    );

    return WorkshopLocalToolchainReport(
      checkedAt: checkedAt,
      flutterAvailable: flutter.available,
      dartAvailable: dart.available,
      javaAvailable: java.available,
      androidSdkAvailable: androidSdk.available,
      offlineCapable: offlineCapable,
      targets: Map.unmodifiable(targets),
      flutterVersion: flutter.version,
      dartVersion: dart.version,
      javaVersion: java.version,
      androidSdkPath: androidSdk.path,
      message: _reportMessage(
        flutter: flutter,
        dart: dart,
        java: java,
        androidSdk: androidSdk,
      ),
    );
  }

  Future<WorkshopToolchainInfo> inspectTarget(
    WorkshopBuildTarget target,
  ) async {
    _ensureAvailable();

    final flutter = await _inspectFlutter();
    final dart = await _inspectDart();
    final java = await _inspectJava();
    final androidSdk =
        await _inspectAndroidSdk();

    return _inspectTarget(
      target: target,
      flutter: flutter,
      dart: dart,
      java: java,
      androidSdk: androidSdk,
    );
  }

  Future<_CommandInspection> _inspectFlutter() async {
    final result = await _run(
      _configuration.flutterExecutable,
      const <String>[
        '--version',
        '--machine',
      ],
    );

    if (!result.success) {
      return _CommandInspection.unavailable(
        executable: _configuration.flutterExecutable,
        message: result.message,
      );
    }

    final version =
        _extractJsonString(
      result.stdout,
      'frameworkVersion',
    );

    return _CommandInspection.available(
      executable: _configuration.flutterExecutable,
      version: version,
      stdout: result.stdout,
    );
  }

  Future<_CommandInspection> _inspectDart() async {
    final result = await _run(
      _configuration.flutterExecutable,
      const <String>[
        'dart',
        '--version',
      ],
    );

    if (!result.success) {
      return _CommandInspection.unavailable(
        executable:
            '${_configuration.flutterExecutable} dart',
        message: result.message,
      );
    }

    return _CommandInspection.available(
      executable:
          '${_configuration.flutterExecutable} dart',
      version: _firstUsefulLine(
        result.stderr.isNotEmpty
            ? result.stderr
            : result.stdout,
      ),
      stdout: result.stdout,
    );
  }

  Future<_CommandInspection> _inspectJava() async {
    final result = await _run(
      _configuration.javaExecutable,
      const <String>[
        '-version',
      ],
    );

    if (!result.success) {
      return _CommandInspection.unavailable(
        executable:
            _configuration.javaExecutable,
        message: result.message,
      );
    }

    final versionOutput =
        result.stderr.isNotEmpty
            ? result.stderr
            : result.stdout;

    return _CommandInspection.available(
      executable:
          _configuration.javaExecutable,
      version:
          _firstUsefulLine(versionOutput),
      stdout: result.stdout,
    );
  }

  Future<_AndroidSdkInspection>
      _inspectAndroidSdk() async {
    final configuredPath =
        _configuration.androidSdkPath;

    final candidates = <String>[
      if (configuredPath != null &&
          configuredPath.trim().isNotEmpty)
        configuredPath,
      _configuration.environment[
            'ANDROID_SDK_ROOT',
          ] ??
          '',
      _configuration.environment[
            'ANDROID_HOME',
          ] ??
          '',
      Platform.environment[
            'ANDROID_SDK_ROOT',
          ] ??
          '',
      Platform.environment[
            'ANDROID_HOME',
          ] ??
          '',
      ..._standardAndroidSdkPaths(),
    ];

    String? sdkPath;

    for (final candidate in candidates) {
      final normalized = candidate.trim();

      if (normalized.isEmpty) {
        continue;
      }

      if (await Directory(normalized).exists()) {
        sdkPath = normalized;
        break;
      }
    }

    if (sdkPath == null) {
      return const _AndroidSdkInspection(
        available: false,
        path: null,
        platformToolsAvailable: false,
        buildToolsAvailable: false,
        platformsAvailable: false,
        message:
            'Android SDK was not found.',
      );
    }

    final platformTools =
        await _directoryExists(
      Directory(
        '$sdkPath/platform-tools',
      ),
    );

    final buildTools =
        await _directoryHasChildDirectory(
      Directory(
        '$sdkPath/build-tools',
      ),
    );

    final platforms =
        await _directoryHasChildDirectory(
      Directory(
        '$sdkPath/platforms',
      ),
    );

    final complete =
        platformTools &&
        buildTools &&
        platforms;

    return _AndroidSdkInspection(
      available: complete,
      path: sdkPath,
      platformToolsAvailable:
          platformTools,
      buildToolsAvailable:
          buildTools,
      platformsAvailable:
          platforms,
      message: complete
          ? 'Android SDK appears complete.'
          : 'Android SDK exists but is incomplete.',
    );
  }

  Future<WorkshopToolchainInfo> _inspectTarget({
    required WorkshopBuildTarget target,
    required _CommandInspection flutter,
    required _CommandInspection dart,
    required _CommandInspection java,
    required _AndroidSdkInspection androidSdk,
  }) async {
    if (!flutter.available) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.unavailable,
        executionMode:
            WorkshopBuildExecutionMode.offlineLocal,
        name: 'Flutter local toolchain',
        path: _configuration.flutterExecutable,
        missingComponents: const <String>[
          'flutter',
        ],
        message:
            'Flutter executable is unavailable.',
      );
    }

    if (!dart.available) {
      return WorkshopToolchainInfo(
        target: target,
        status: WorkshopToolchainStatus.incomplete,
        executionMode:
            WorkshopBuildExecutionMode.offlineLocal,
        name: 'Flutter local toolchain',
        path: _configuration.flutterExecutable,
        version: flutter.version,
        missingComponents: const <String>[
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
          androidSdk: androidSdk,
        );

      case WorkshopBuildTarget.web:
        return _webInfo(
          flutter: flutter,
        );

      case WorkshopBuildTarget.windows:
        return _windowsInfo(
          flutter: flutter,
        );

      case WorkshopBuildTarget.linux:
        return _linuxInfo(
          flutter: flutter,
        );

      case WorkshopBuildTarget.macos:
        return _macosInfo(
          flutter: flutter,
        );

      case WorkshopBuildTarget.ios:
        return _iosInfo(
          flutter: flutter,
        );
    }
  }

  WorkshopToolchainInfo _androidInfo({
    required _CommandInspection flutter,
    required _CommandInspection java,
    required _AndroidSdkInspection androidSdk,
  }) {
    final missing =
        <String>[];

    if (!java.available) {
      missing.add('java');
    }

    if (!androidSdk.available) {
      if (!androidSdk.platformToolsAvailable) {
        missing.add('android_platform_tools');
      }

      if (!androidSdk.buildToolsAvailable) {
        missing.add('android_build_tools');
      }

      if (!androidSdk.platformsAvailable) {
        missing.add('android_platforms');
      }
    }

    final available =
        missing.isEmpty &&
        _hostCanRunAndroid();

    if (!available &&
        !_hostCanRunAndroid()) {
      missing.add('android_local_execution_host');
    }

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.android,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.incomplete,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter + Android local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents:
          List.unmodifiable(missing),
      message: available
          ? 'Android can be built locally with the '
              'currently detected toolchain.'
          : 'Android local build is not currently '
              'guaranteed by the detected environment.',
    );
  }

  WorkshopToolchainInfo _webInfo({
    required _CommandInspection flutter,
  }) {
    final available =
        _hostCanRunFlutter();

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.web,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter Web local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents: available
          ? const <String>[]
          : const <String>[
              'flutter_local_execution_host',
            ],
      message: available
          ? 'Flutter Web can be built locally.'
          : 'Flutter executable cannot be executed '
              'by the current host.',
    );
  }

  WorkshopToolchainInfo _windowsInfo({
    required _CommandInspection flutter,
  }) {
    final available =
        Platform.isWindows &&
        _hostCanRunFlutter();

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.windows,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter Windows local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents: available
          ? const <String>[]
          : const <String>[
              'windows_build_host',
            ],
      message: available
          ? 'Windows target can be evaluated locally.'
          : 'Windows requires a Windows build host.',
    );
  }

  WorkshopToolchainInfo _linuxInfo({
    required _CommandInspection flutter,
  }) {
    final available =
        Platform.isLinux &&
        _hostCanRunFlutter();

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.linux,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter Linux local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents: available
          ? const <String>[]
          : const <String>[
              'linux_build_host',
            ],
      message: available
          ? 'Linux target can be evaluated locally.'
          : 'Linux requires a Linux build host.',
    );
  }

  WorkshopToolchainInfo _macosInfo({
    required _CommandInspection flutter,
  }) {
    final available =
        Platform.isMacOS &&
        _hostCanRunFlutter();

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.macos,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter macOS local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents: available
          ? const <String>[]
          : const <String>[
              'macos_build_host',
            ],
      message: available
          ? 'macOS target can be evaluated locally.'
          : 'macOS requires a macOS build host.',
    );
  }

  WorkshopToolchainInfo _iosInfo({
    required _CommandInspection flutter,
  }) {
    final available =
        Platform.isMacOS &&
        _hostCanRunFlutter();

    return WorkshopToolchainInfo(
      target: WorkshopBuildTarget.ios,
      status: available
          ? WorkshopToolchainStatus.available
          : WorkshopToolchainStatus.unavailable,
      executionMode:
          WorkshopBuildExecutionMode.offlineLocal,
      name: 'Flutter iOS local toolchain',
      version: flutter.version,
      path: _configuration.flutterExecutable,
      missingComponents: available
          ? const <String>[]
          : const <String>[
              'ios_build_host',
            ],
      message: available
          ? 'iOS target can be evaluated locally.'
          : 'iOS requires a macOS/Xcode build host.',
    );
  }

  bool _hostCanRunFlutter() {
    if (Platform.isAndroid) {
      // Questo è volutamente conservativo.
      //
      // Avere un binario Flutter archiviato sul dispositivo
      // non significa automaticamente avere un ambiente POSIX
      // completo in cui eseguirlo.
      return false;
    }

    return Platform.isLinux ||
        Platform.isWindows ||
        Platform.isMacOS;
  }

  bool _hostCanRunAndroid() {
    return Platform.isLinux ||
        Platform.isWindows ||
        Platform.isMacOS;
  }

  List<String> _standardAndroidSdkPaths() {
    if (Platform.isWindows) {
      final localAppData =
          Platform.environment['LOCALAPPDATA'];

      if (localAppData != null &&
          localAppData.isNotEmpty) {
        return <String>[
          '$localAppData/Android/Sdk',
        ];
      }
    }

    final home =
        Platform.environment['HOME'];

    if (home != null &&
        home.isNotEmpty) {
      return <String>[
        '$home/Android/Sdk',
        '$home/android-sdk',
      ];
    }

    return const <String>[];
  }

  Future<bool> _directoryExists(
    Directory directory,
  ) {
    return directory.exists();
  }

  Future<bool> _directoryHasChildDirectory(
    Directory directory,
  ) async {
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

  Future<_CommandResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final environment = <String, String>{
        ...Platform.environment,
        ..._configuration.environment,
      };

      final process = await Process.start(
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

      final exitCodeFuture =
          process.exitCode;

      final exitCode =
          await exitCodeFuture.timeout(
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

  String? _extractJsonString(
    String output,
    String key,
  ) {
    final trimmed =
        output.trim();

    if (trimmed.isEmpty) {
      return null;
    }

    try {
      final decoded =
          jsonDecode(trimmed);

      if (decoded is Map &&
          decoded[key] is String) {
        return decoded[key] as String;
      }
    } catch (_) {
      // Flutter potrebbe produrre output
      // aggiuntivo. Utilizziamo il fallback.
    }

    return _firstUsefulLine(trimmed);
  }

  String? _firstUsefulLine(
    String value,
  ) {
    for (final line
        in value.split(RegExp(r'\r?\n'))) {
      final trimmed =
          line.trim();

      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    return null;
  }

  String? _reportMessage({
    required _CommandInspection flutter,
    required _CommandInspection dart,
    required _CommandInspection java,
    required _AndroidSdkInspection androidSdk,
  }) {
    if (!flutter.available) {
      return 'Flutter SDK is not available.';
    }

    if (!dart.available) {
      return 'Flutter is available but Dart could not be verified.';
    }

    if (!java.available) {
      return 'Java is not available.';
    }

    if (!androidSdk.available) {
      return 'Flutter is available, but the Android SDK '
          'is incomplete or unavailable.';
    }

    return 'Local toolchain inspection completed.';
  }

  Future<void> dispose() async {
    _disposed = true;
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopLocalToolchainDetector '
        'has been disposed.',
      );
    }
  }
}

final class _CommandInspection {
  const _CommandInspection({
    required this.available,
    this.executable,
    this.version,
    this.stdout = '',
    this.message,
  });

  factory _CommandInspection.available({
    required String executable,
    String? version,
    String stdout = '',
  }) {
    return _CommandInspection(
      available: true,
      executable: executable,
      version: version,
      stdout: stdout,
    );
  }

  factory _CommandInspection.unavailable({
    required String executable,
    String? message,
  }) {
    return _CommandInspection(
      available: false,
      executable: executable,
      message: message,
    );
  }

  final bool available;
  final String? executable;
  final String? version;
  final String stdout;
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

final class _AndroidSdkInspection {
  const _AndroidSdkInspection({
    required this.available,
    required this.path,
    required this.platformToolsAvailable,
    required this.buildToolsAvailable,
    required this.platformsAvailable,
    required this.message,
  });

  final bool available;
  final String? path;

  final bool platformToolsAvailable;
  final bool buildToolsAvailable;
  final bool platformsAvailable;

  final String message;
}
