import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_detector.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_service.dart';

/// Production adapter that connects Cantiere's authoritative local-toolchain
/// inspection to the existing Flutter local build executor.
///
/// The provider fails closed: a build is delegated only after the authoritative
/// [WorkshopLocalToolchainService] reports that the requested target is really
/// available on the current host. Inspection and execution resolve the same
/// Flutter executable and receive the same environment.
final class WorkshopVerifiedLocalBuildProvider
    implements WorkshopBuildProvider {
  WorkshopVerifiedLocalBuildProvider({
    WorkshopLocalToolchainService? toolchainService,
    WorkshopLocalBuildProvider? delegate,
    String flutterExecutable = 'flutter',
    String javaExecutable = 'java',
    String? androidSdkPath,
    Map<String, String> environment = const <String, String>{},
    Duration inspectionTimeout = const Duration(seconds: 15),
    Duration buildTimeout = const Duration(minutes: 30),
  })  : _toolchainService = toolchainService ??
            WorkshopLocalToolchainService(
              detector: WorkshopLocalToolchainDetector(
                configuration: WorkshopLocalToolchainDetectorConfiguration(
                  flutterExecutable: _resolveExecutable(
                    flutterExecutable,
                    environment,
                  ),
                  dartExecutable: _resolveDartExecutable(
                    flutterExecutable,
                    environment,
                  ),
                  javaExecutable: _resolveExecutable(
                    javaExecutable,
                    environment,
                  ),
                  androidSdkPath: androidSdkPath,
                  environment: environment,
                  timeout: inspectionTimeout,
                ),
              ),
            ),
        _delegate = delegate ??
            WorkshopLocalBuildProvider(
              configuration: WorkshopLocalBuildConfiguration(
                flutterExecutable: _resolveExecutable(
                  flutterExecutable,
                  environment,
                ),
                environment: environment,
                timeout: buildTimeout,
              ),
            );

  final WorkshopLocalToolchainService _toolchainService;
  final WorkshopLocalBuildProvider _delegate;

  @override
  WorkshopBuildExecutionMode get executionMode =>
      WorkshopBuildExecutionMode.offlineLocal;

  @override
  Future<WorkshopToolchainInfo> inspectToolchain(
    WorkshopBuildTarget target,
  ) {
    return _toolchainService.inspectTarget(target);
  }

  @override
  Future<WorkshopBuildResult> build(
    WorkshopBuildRequest request,
  ) async {
    final startedAt = DateTime.now();
    final toolchain = await inspectToolchain(request.target);

    if (!toolchain.isAvailable) {
      return WorkshopBuildResult(
        requestId: request.id,
        target: request.target,
        status: WorkshopBuildStatus.failed,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        message: toolchain.message ??
            'Verified local toolchain is unavailable for ${request.target.name}.',
        errors: <String>[
          'verified_local_toolchain_unavailable',
          ...toolchain.missingComponents,
        ],
      );
    }

    return _delegate.build(request);
  }

  @override
  Future<void> cancel(String requestId) => _delegate.cancel(requestId);

  Future<void> dispose() async {
    await _delegate.dispose();
  }

  static String _resolveDartExecutable(
    String flutterExecutable,
    Map<String, String> environment,
  ) {
    final resolvedFlutter = _resolveExecutable(
      flutterExecutable,
      environment,
    );
    final flutterFile = File(resolvedFlutter);
    final hasExplicitPath = flutterFile.isAbsolute ||
        resolvedFlutter.contains(Platform.pathSeparator);
    if (hasExplicitPath) {
      final siblingName = Platform.isWindows ? 'dart.bat' : 'dart';
      final sibling = File(
        '${flutterFile.parent.path}${Platform.pathSeparator}$siblingName',
      );
      if (sibling.existsSync()) {
        return sibling.absolute.path;
      }
    }
    return _resolveExecutable('dart', environment);
  }

  static String _resolveExecutable(
    String executable,
    Map<String, String> environment,
  ) {
    final normalized = executable.trim();
    if (normalized.isEmpty) return executable;

    final direct = File(normalized);
    if (direct.isAbsolute && direct.existsSync()) {
      return direct.path;
    }
    if (normalized.contains(Platform.pathSeparator) && direct.existsSync()) {
      return direct.absolute.path;
    }

    final mergedEnvironment = <String, String>{
      ...Platform.environment,
      ...environment,
    };
    final path = mergedEnvironment['PATH'];
    if (path == null || path.trim().isEmpty) return normalized;

    final suffixes = Platform.isWindows
        ? const <String>['', '.bat', '.cmd', '.exe']
        : const <String>[''];
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      final root = directory.trim();
      if (root.isEmpty) continue;
      for (final suffix in suffixes) {
        final candidate = File(
          '$root${Platform.pathSeparator}$normalized$suffix',
        );
        if (candidate.existsSync()) {
          return candidate.absolute.path;
        }
      }
    }

    return normalized;
  }
}
