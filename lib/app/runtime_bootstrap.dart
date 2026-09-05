import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_credential_store.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/system/update/version_parser.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class RuntimeBootstrap {
  const RuntimeBootstrap();

  static const String _versionFallback = '1.0.12+12';
  static const VersionParser _versionParser = VersionParser();

  Future<void> initialize() async {
    debugPrint('[BOOT] init begin');
    RuntimeEventLog.instance.emit('[FORENSIC_DIAGNOSTICS_PIPELINE_VERIFIED]');
    final appVersion = await _resolveAppVersion();

    const openAiApiKey = String.fromEnvironment('OPENAI_API_KEY');
    const geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
    const claudeApiKey = String.fromEnvironment('CLAUDE_API_KEY');
    const grokApiKey = String.fromEnvironment('GROK_API_KEY');
    const copilotApiKey = String.fromEnvironment('COPILOT_API_KEY');

    await _initializeCloudCredentials(
      <String, String>{
        'openAi': openAiApiKey,
        'gemini': geminiApiKey,
        'claude': claudeApiKey,
        'grok': grokApiKey,
        'copilot': copilotApiKey,
      },
    );

    await di.initDependencies(
      openAiApiKey: openAiApiKey,
      geminiApiKey: geminiApiKey,
      claudeApiKey: claudeApiKey,
      grokApiKey: grokApiKey,
      copilotApiKey: copilotApiKey,
      appVersion: appVersion,
    );

    await _runWarmupChecks();
    debugPrint('[BOOT] init complete');
  }

  Future<void> _initializeCloudCredentials(
    Map<String, String> environmentFallbacks,
  ) async {
    try {
      await CloudCredentialStore.instance.initialize(
        environmentFallbacks: environmentFallbacks,
      );
      final configured = CloudCredentialStore.instance.snapshots
          .where((snapshot) => snapshot.configured)
          .length;
      debugPrint(
        '[CLOUD_CREDENTIALS] secure credential store ready; '
        'configuredProviders=$configured',
      );
    } catch (error) {
      // Cloud credential storage must never make Local mode unavailable.
      // Datasources still receive build-time values through DI as a dev/CI
      // fallback, without persisting those values or printing any secret.
      debugPrint(
        '[CLOUD_CREDENTIALS] secure storage unavailable; using '
        'non-persistent environment fallback when configured: $error',
      );
    }
  }

  Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final rawVersion = info.version.isNotEmpty ? info.version : _versionFallback;
      final rawPackageVersion = rawVersion.contains('+')
          ? rawVersion
          : (info.buildNumber.isNotEmpty ? '$rawVersion+${info.buildNumber}' : rawVersion);
      final normalizedVersion =
          _versionParser.normalize(rawPackageVersion) ?? rawPackageVersion;
      debugPrint('[OTA] PackageInfo version resolved: $normalizedVersion');
      debugPrint('[OTA] PackageInfo raw: version=${info.version} buildNumber=${info.buildNumber}');
      return normalizedVersion;
    } catch (error) {
      const version = String.fromEnvironment(
        'APP_VERSION',
        defaultValue: _versionFallback,
      );
      final fallbackVersion = version.contains('+') ? version : '$version+0';
      final normalizedVersion =
          _versionParser.normalize(fallbackVersion) ?? fallbackVersion;
      debugPrint('[OTA] PackageInfo failed ($error), using fallback: $normalizedVersion');
      return normalizedVersion;
    }
  }

  Future<void> _runWarmupChecks() async {
    debugPrint('[WARMUP] startup checks begin');
    await Future.wait<void>([
      _critical('database', () async {
        final _ = await di.sl<DatabaseHelper>().database;
      }),
      _critical(
        'runtime_mode',
        () async {
          await di.sl<AiRuntimeSettingsService>().loadRuntimeMode();
        },
      ),
      _critical(
        'model_checks',
        () async {
          await di.sl<LocalAiRepository>().getSelectedModel();
        },
      ),
    ]);

    // Optional preload checks should never crash startup.
    // Intentionally resolve singleton once to force lazy service construction.
    di.sl<PreferencesService>();
    await _guarded('orchestrator_boot', () async {
      // Intentionally resolve singleton once to warm orchestration graph.
      di.sl<Orchestrator>();
    });

    // Loud diagnostic: if the user selected local mode but the runtime is not
    // ready, emit a prominent log so CI logs and device logs make the gap
    // immediately visible.  This is a best-effort check and must never throw.
    await _guarded('local_runtime_startup_check', () async {
      final runtimeMode = await di.sl<AiRuntimeSettingsService>().loadRuntimeMode();
      if (runtimeMode != AiRuntimeMode.local) return;
      debugPrint('[STARTUP_WARN] AI mode=local — validating local runtime before first use…');
      final diagnostics = di.sl<LocalRuntimeDiagnosticsService>();
      await diagnostics.refresh();
      final state = diagnostics.monitor.state;
      if (state.status == LocalRuntimeStatus.ffiMissing ||
          state.status == LocalRuntimeStatus.modelMissing ||
          state.status == LocalRuntimeStatus.failed ||
          state.status == LocalRuntimeStatus.runtimeUnavailable) {
        debugPrint(
          '[STARTUP_ERROR] LOCAL MODE SELECTED BUT RUNTIME NOT READY — '
          'status=${state.status.name} message="${state.message ?? "none"}"',
        );
      } else {
        debugPrint(
          '[STARTUP_OK] local runtime status=${state.status.name}',
        );
      }
    });
    debugPrint('[WARMUP] startup checks complete');
  }

  Future<void> _guarded(String label, Future<void> Function() task) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('[BOOTSTRAP] Warmup check failed ($label): $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _critical(String label, Future<void> Function() task) async {
    try {
      await task();
    } catch (error) {
      throw StateError('Critical startup check failed ($label): $error');
    }
  }
}
