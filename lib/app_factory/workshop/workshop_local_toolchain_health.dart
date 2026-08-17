import 'dart:async';
import 'dart:io';

/// Stato della toolchain locale.
enum WorkshopLocalToolchainHealthStatus {
  available,
  unavailable,
  partiallyAvailable,
  unknown,
}

/// Risultato di un singolo controllo.
final class WorkshopLocalToolchainCheck {
  const WorkshopLocalToolchainCheck({
    required this.name,
    required this.available,
    this.version,
    this.message,
    this.duration = Duration.zero,
  });

  final String name;
  final bool available;
  final String? version;
  final String? message;
  final Duration duration;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'available': available,
      'version': version,
      'message': message,
      'durationMs': duration.inMilliseconds,
    };
  }
}

/// Risultato complessivo del controllo della toolchain.
final class WorkshopLocalToolchainHealth {
  const WorkshopLocalToolchainHealth({
    required this.status,
    required this.checkedAt,
    required this.dart,
    required this.flutter,
    required this.android,
    required this.targets,
    required this.offlineCapable,
    this.message,
  });

  final WorkshopLocalToolchainHealthStatus status;
  final DateTime checkedAt;

  final WorkshopLocalToolchainCheck dart;
  final WorkshopLocalToolchainCheck flutter;
  final WorkshopLocalToolchainCheck android;

  /// Target che possono essere considerati localmente plausibili.
  final List<String> targets;

  /// Indica se la toolchain locale appare utilizzabile senza rete.
  ///
  /// Questo valore è conservativo: non significa che tutte le
  /// dipendenze del progetto siano già disponibili offline.
  final bool offlineCapable;

  final String? message;

  bool get isAvailable =>
      status == WorkshopLocalToolchainHealthStatus.available;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'status': status.name,
      'checkedAt': checkedAt.toUtc().toIso8601String(),
      'dart': dart.toJson(),
      'flutter': flutter.toJson(),
      'android': android.toJson(),
      'targets': targets,
      'offlineCapable': offlineCapable,
      'message': message,
    };
  }
}

/// Verificatore della salute della toolchain locale.
///
/// Questo componente NON:
///
/// - installa Flutter;
/// - installa Android SDK;
/// - esegue pub get;
/// - scarica dipendenze;
/// - modifica il repository;
/// - avvia build.
///
/// Esegue esclusivamente controlli diagnostici leggeri.
///
/// Architettura:
///
///   Detector
///       ↓
///   Health
///       ↓
///   Local Toolchain Bridge
///       ↓
///   Local Task Executor
final class WorkshopLocalToolchainHealthChecker {
  WorkshopLocalToolchainHealthChecker({
    this.timeout = const Duration(seconds: 8),
  });

  final Duration timeout;

  Future<WorkshopLocalToolchainHealth> check() async {
    final checkedAt = DateTime.now().toUtc();

    final dart = await _checkExecutable(
      name: 'dart',
      arguments: const <String>['--version'],
    );

    final flutter = await _checkExecutable(
      name: 'flutter',
      arguments: const <String>['--version'],
    );

    final android = _checkAndroidEnvironment();

    final targets = _detectTargets(
      dart: dart.available,
      flutter: flutter.available,
      android: android.available,
    );

    final status = _calculateStatus(
      dart: dart.available,
      flutter: flutter.available,
      android: android.available,
    );

    final offlineCapable =
        dart.available &&
        flutter.available &&
        _offlineEnvironmentLooksUsable();

    return WorkshopLocalToolchainHealth(
      status: status,
      checkedAt: checkedAt,
      dart: dart,
      flutter: flutter,
      android: android,
      targets: targets,
      offlineCapable: offlineCapable,
      message: _buildMessage(
        status: status,
        dart: dart,
        flutter: flutter,
        android: android,
        offlineCapable: offlineCapable,
      ),
    );
  }

  Future<WorkshopLocalToolchainCheck> _checkExecutable({
    required String name,
    required List<String> arguments,
  }) async {
    final startedAt = DateTime.now();

    try {
      final result = await Process.run(
        name,
        arguments,
        runInShell: false,
      ).timeout(timeout);

      final duration =
          DateTime.now().difference(startedAt);

      final output = [
        result.stdout.toString(),
        result.stderr.toString(),
      ].join('\n').trim();

      final available = result.exitCode == 0;

      return WorkshopLocalToolchainCheck(
        name: name,
        available: available,
        version: available
            ? _extractVersion(output)
            : null,
        message: available
            ? 'Executable is available.'
            : output.isEmpty
                ? 'Executable returned exit code '
                    '${result.exitCode}.'
                : output,
        duration: duration,
      );
    } on TimeoutException {
      return WorkshopLocalToolchainCheck(
        name: name,
        available: false,
        message: 'Toolchain check timed out.',
        duration: DateTime.now().difference(startedAt),
      );
    } on ProcessException catch (error) {
      return WorkshopLocalToolchainCheck(
        name: name,
        available: false,
        message: error.message,
        duration: DateTime.now().difference(startedAt),
      );
    } catch (error) {
      return WorkshopLocalToolchainCheck(
        name: name,
        available: false,
        message: error.toString(),
        duration: DateTime.now().difference(startedAt),
      );
    }
  }

  WorkshopLocalToolchainCheck _checkAndroidEnvironment() {
    final androidHome =
        Platform.environment['ANDROID_HOME'];

    final androidSdkRoot =
        Platform.environment['ANDROID_SDK_ROOT'];

    final path =
        androidSdkRoot?.trim().isNotEmpty == true
            ? androidSdkRoot!.trim()
            : androidHome?.trim();

    if (path == null || path.isEmpty) {
      return const WorkshopLocalToolchainCheck(
        name: 'android-sdk',
        available: false,
        message:
            'ANDROID_HOME or ANDROID_SDK_ROOT is not configured.',
      );
    }

    final directory = Directory(path);

    if (!directory.existsSync()) {
      return WorkshopLocalToolchainCheck(
        name: 'android-sdk',
        available: false,
        message:
            'Configured Android SDK directory does not exist.',
      );
    }

    return WorkshopLocalToolchainCheck(
      name: 'android-sdk',
      available: true,
      version: path,
      message: 'Android SDK directory is available.',
    );
  }

  List<String> _detectTargets({
    required bool dart,
    required bool flutter,
    required bool android,
  }) {
    if (!flutter) {
      return const <String>[];
    }

    final targets = <String>[];

    if (Platform.isAndroid && android) {
      targets.add('android');
    }

    if (Platform.isWindows) {
      targets.add('windows');
    }

    if (Platform.isLinux) {
      targets.add('linux');
    }

    if (Platform.isMacOS) {
      targets.add('macos');
    }

    if (Platform.isAndroid &&
        dart &&
        flutter) {
      targets.add('dart');
    }

    return List.unmodifiable(targets);
  }

  WorkshopLocalToolchainHealthStatus _calculateStatus({
    required bool dart,
    required bool flutter,
    required bool android,
  }) {
    if (flutter && dart && android) {
      return WorkshopLocalToolchainHealthStatus.available;
    }

    if (flutter || dart || android) {
      return WorkshopLocalToolchainHealthStatus
          .partiallyAvailable;
    }

    return WorkshopLocalToolchainHealthStatus.unavailable;
  }

  bool _offlineEnvironmentLooksUsable() {
    final pubCache =
        Platform.environment['PUB_CACHE'];

    if (pubCache != null &&
        pubCache.trim().isNotEmpty) {
      return Directory(pubCache).existsSync();
    }

    final home =
        Platform.environment['HOME'];

    if (home != null &&
        home.trim().isNotEmpty) {
      final defaultPubCache = Directory(
        '$home/.pub-cache',
      );

      if (defaultPubCache.existsSync()) {
        return true;
      }
    }

    return false;
  }

  String? _extractVersion(String output) {
    final normalized = output.trim();

    if (normalized.isEmpty) {
      return null;
    }

    final lines = normalized
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);

    if (lines.isEmpty) {
      return null;
    }

    return lines.first;
  }

  String _buildMessage({
    required WorkshopLocalToolchainHealthStatus status,
    required WorkshopLocalToolchainCheck dart,
    required WorkshopLocalToolchainCheck flutter,
    required WorkshopLocalToolchainCheck android,
    required bool offlineCapable,
  }) {
    switch (status) {
      case WorkshopLocalToolchainHealthStatus.available:
        if (offlineCapable) {
          return 'Local Flutter toolchain is available and '
              'appears suitable for offline work.';
        }

        return 'Local Flutter toolchain is available, but '
            'offline dependency availability could not be confirmed.';

      case WorkshopLocalToolchainHealthStatus
            .partiallyAvailable:
        return 'Local toolchain is only partially available. '
            'Dart=${dart.available}, '
            'Flutter=${flutter.available}, '
            'Android SDK=${android.available}.';

      case WorkshopLocalToolchainHealthStatus.unavailable:
        return 'Required local toolchain components are unavailable.';

      case WorkshopLocalToolchainHealthStatus.unknown:
        return 'Local toolchain health could not be determined.';
    }
  }
}
