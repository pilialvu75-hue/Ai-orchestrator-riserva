import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:ai_orchestrator/core/database/database_helper.dart';
import 'package:ai_orchestrator/core/orchestrator/orchestrator.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings_service.dart';
import 'package:ai_orchestrator/core/runtime/preferences_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/repositories/local_ai_repository.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

class RuntimeBootstrap {
  const RuntimeBootstrap();

  static const String _versionFallback = '1.0.12';

  Future<void> initialize() async {
    final appVersion = await _resolveAppVersion();

    await di.initDependencies(
      openAiApiKey: const String.fromEnvironment('OPENAI_API_KEY'),
      geminiApiKey: const String.fromEnvironment('GEMINI_API_KEY'),
      claudeApiKey: const String.fromEnvironment('CLAUDE_API_KEY'),
      grokApiKey: const String.fromEnvironment('GROK_API_KEY'),
      copilotApiKey: const String.fromEnvironment('COPILOT_API_KEY'),
      appVersion: appVersion,
    );

    await _runWarmupChecks();
  }

  Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version =
          info.version.isNotEmpty ? info.version : _versionFallback;
      debugPrint('[OTA] PackageInfo version: ${info.version}+${info.buildNumber}');
      return version;
    } catch (error) {
      final version = const String.fromEnvironment(
        'APP_VERSION',
        defaultValue: _versionFallback,
      );
      debugPrint('[OTA] PackageInfo failed ($error), using fallback: $version');
      return version;
    }
  }

  Future<void> _runWarmupChecks() async {
    await Future.wait<void>([
      _critical('database', () => di.sl<DatabaseHelper>().database.then((_) {})),
      _critical(
        'runtime_mode',
        () => di.sl<AiRuntimeSettingsService>().loadRuntimeMode().then((_) {}),
      ),
      _critical(
        'model_checks',
        () => di.sl<LocalAiRepository>().getSelectedModel().then((_) {}),
      ),
    ]);

    // Optional preload checks should never crash startup.
    di.sl<PreferencesService>();
    await _guarded('orchestrator_boot', () async {
      di.sl<Orchestrator>();
    });
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
