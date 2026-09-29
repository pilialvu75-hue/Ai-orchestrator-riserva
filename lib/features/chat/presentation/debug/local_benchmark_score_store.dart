import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:flutter/foundation.dart';

enum LocalBenchmarkComponent {
  quick,
  quality,
  performance,
  vulkan,
  thermal,
  memoryContext,
  multilingual,
  stability,
}

class LocalBenchmarkComponentScore {
  const LocalBenchmarkComponentScore({
    required this.score,
    required this.updatedAt,
  });

  final int score;
  final DateTime updatedAt;

  Map<String, Object> toJson() => <String, Object>{
        'score': score,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static LocalBenchmarkComponentScore? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final score = raw['score'];
    final updatedAt = raw['updatedAt'];
    if (score is! num || updatedAt is! String) return null;
    final parsed = DateTime.tryParse(updatedAt);
    if (parsed == null) return null;
    return LocalBenchmarkComponentScore(
      score: score.round().clamp(0, 100).toInt(),
      updatedAt: parsed,
    );
  }
}

class LocalModelBenchmarkScore {
  const LocalModelBenchmarkScore({
    required this.modelId,
    required this.fingerprint,
    required this.components,
  });

  final String modelId;
  final String fingerprint;
  final Map<LocalBenchmarkComponent, LocalBenchmarkComponentScore> components;

  int? get generalScore {
    if (components.isEmpty) return null;

    final values = components.values
        .map((component) => component.score)
        .toList(growable: false);
    return (values.reduce((a, b) => a + b) / values.length)
        .round()
        .clamp(0, 100);
  }

  int get completedComponents => components.length;

  static const int totalComponents = 8;
}

abstract final class LocalBenchmarkScoring {
  static int quickScore(LocalModelBenchmarkModelResult result) {
    final quality = result.maxScore <= 0
        ? 0.0
        : (result.score / result.maxScore * 100).clamp(0.0, 100.0);

    final firstMs = result.averageFirstContentMs;
    final responsiveness = firstMs <= 1000
        ? 100.0
        : firstMs >= 10000
            ? 0.0
            : (100 - ((firstMs - 1000) / 90)).clamp(0.0, 100.0);

    final decode = result.averageDecodeTokensPerSecond;
    final throughput = decode <= 3
        ? 0.0
        : decode >= 15
            ? 100.0
            : ((decode - 3) / 12 * 100).clamp(0.0, 100.0);

    return (quality * 0.70 + responsiveness * 0.15 + throughput * 0.15)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  static int qualityScore(LocalModelBenchmarkModelResult result) {
    if (result.maxScore <= 0) return 0;
    return (result.score / result.maxScore * 100)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  static int performanceScore(LocalModelPerformanceModelResult result) {
    final cold = result.coldSample?.result;
    if (cold == null ||
        result.warmSamples.isEmpty ||
        !result.coldSessionConfirmed ||
        !result.warmSessionConfirmed) {
      return 0;
    }

    final coldFirst = _lowerIsBetter(
      cold.firstContentMs.toDouble(),
      best: 1500,
      worst: 15000,
    );
    final warmFirst = _lowerIsBetter(
      result.averageWarmFirstContentMs,
      best: 750,
      worst: 7500,
    );
    final warmPrefill = result.averageWarmPrefillMs <= 0
        ? 0.0
        : _lowerIsBetter(
            result.averageWarmPrefillMs,
            best: 400,
            worst: 4000,
          );
    final warmDecode = _higherIsBetter(
      result.averageWarmDecodeTokensPerSecond,
      worst: 4,
      best: 20,
    );

    return (coldFirst * 0.25 +
            warmFirst * 0.25 +
            warmPrefill * 0.20 +
            warmDecode * 0.30)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  static int? thermalScore(LocalModelThermalStressResult result) {
    if (!result.hasValidThermalTelemetry ||
        result.samples.isEmpty ||
        result.criticalResourceStop ||
        result.failure != null) {
      return null;
    }

    final start = result.startBatteryTemperatureC!;
    final max = result.maxBatteryTemperatureC!;
    final rise = (max - start).clamp(0.0, 100.0);

    final riseScore = _lowerIsBetter(
      rise,
      best: 1.0,
      worst: 8.0,
    );
    final peakScore = _lowerIsBetter(
      max,
      best: 35.0,
      worst: 45.0,
    );
    final stabilityScore = result.targetRepetitions <= 0
        ? 0.0
        : (result.completedRepetitions / result.targetRepetitions * 100)
            .clamp(0.0, 100.0);
    final pressureScore = result.samples.isEmpty
        ? 0.0
        : (100 -
                (result.pressuredSamples / result.samples.length * 100))
            .clamp(0.0, 100.0);

    return (riseScore * 0.40 +
            peakScore * 0.30 +
            stabilityScore * 0.20 +
            pressureScore * 0.10)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  static double _lowerIsBetter(
    double value, {
    required double best,
    required double worst,
  }) {
    if (value <= best) return 100;
    if (value >= worst) return 0;
    return ((worst - value) / (worst - best) * 100).clamp(0, 100);
  }

  static double _higherIsBetter(
    double value, {
    required double worst,
    required double best,
  }) {
    if (value <= worst) return 0;
    if (value >= best) return 100;
    return ((value - worst) / (best - worst) * 100).clamp(0, 100);
  }
}

class LocalBenchmarkScoreStore {
  LocalBenchmarkScoreStore(
    this._preferences, {
    Future<String> Function()? hardwareProfileProvider,
  }) : _hardwareProfileProvider =
            hardwareProfileProvider ?? _defaultHardwareProfile;

  static const String _storageKey = 'debug_local_benchmark_scores_v1';

  final PreferencesService _preferences;
  final Future<String> Function() _hardwareProfileProvider;
  Future<String>? _cachedHardwareProfile;

  Future<String> hardwareProfile() =>
      _cachedHardwareProfile ??= _hardwareProfileProvider();

  static Future<String> _defaultHardwareProfile() async {
    if (kIsWeb) return 'web';
    if (defaultTargetPlatform == TargetPlatform.android) {
      final sample = await ResourceMonitor.instance.sample();
      return sample?.benchmarkHardwareProfile ?? 'android|unknown';
    }
    return 'platform:${defaultTargetPlatform.name}';
  }

  Future<Map<String, LocalModelBenchmarkScore>> loadForModels(
    Iterable<AiModel> models,
  ) async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return const <String, LocalModelBenchmarkScore>{};
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const <String, LocalModelBenchmarkScore>{};
    }
    if (decoded is! Map<String, dynamic>) {
      return const <String, LocalModelBenchmarkScore>{};
    }

    final modelMap = decoded['models'];
    if (modelMap is! Map) {
      return const <String, LocalModelBenchmarkScore>{};
    }

    final currentHardwareProfile = await hardwareProfile();
    final output = <String, LocalModelBenchmarkScore>{};
    for (final model in models) {
      final entry = modelMap[model.id];
      if (entry is! Map) continue;

      final fingerprint = entry['fingerprint'];
      if (fingerprint != fingerprintFor(model)) continue;

      final storedHardwareProfile = entry['hardwareProfile'];
      // Legacy local records did not have a hardware profile. They remain
      // readable on the same installation and are upgraded on next save.
      if (storedHardwareProfile is String &&
          storedHardwareProfile != currentHardwareProfile) {
        continue;
      }

      final rawComponents = entry['components'];
      if (rawComponents is! Map) continue;

      final components =
          <LocalBenchmarkComponent, LocalBenchmarkComponentScore>{};
      for (final component in LocalBenchmarkComponent.values) {
        final parsed = LocalBenchmarkComponentScore.fromJson(
          rawComponents[component.name],
        );
        if (parsed != null) {
          components[component] = parsed;
        }
      }

      output[model.id] = LocalModelBenchmarkScore(
        modelId: model.id,
        fingerprint: fingerprint as String,
        components: Map<LocalBenchmarkComponent,
            LocalBenchmarkComponentScore>.unmodifiable(components),
      );
    }

    return Map<String, LocalModelBenchmarkScore>.unmodifiable(output);
  }

  Future<void> saveComponent({
    required AiModel model,
    required LocalBenchmarkComponent component,
    required int score,
    DateTime? updatedAt,
  }) async {
    Map<String, dynamic> root;
    final raw = _preferences.getString(_storageKey);
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      root = decoded is Map<String, dynamic>
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      root = <String, dynamic>{};
    }

    final models = root['models'] is Map
        ? Map<String, dynamic>.from(root['models'] as Map)
        : <String, dynamic>{};

    final fingerprint = fingerprintFor(model);
    final currentHardwareProfile = await hardwareProfile();
    final existing = models[model.id];
    Map<String, dynamic> entry;
    final existingHardwareProfile =
        existing is Map ? existing['hardwareProfile'] : null;
    final hardwareCompatible = existingHardwareProfile == null ||
        existingHardwareProfile == currentHardwareProfile;
    if (existing is Map &&
        existing['fingerprint'] == fingerprint &&
        hardwareCompatible) {
      entry = Map<String, dynamic>.from(existing);
    } else {
      entry = <String, dynamic>{
        'modelId': model.id,
        'fingerprint': fingerprint,
        'hardwareProfile': currentHardwareProfile,
        'components': <String, dynamic>{},
      };
    }
    entry['hardwareProfile'] = currentHardwareProfile;

    final components = entry['components'] is Map
        ? Map<String, dynamic>.from(entry['components'] as Map)
        : <String, dynamic>{};
    components[component.name] = LocalBenchmarkComponentScore(
      score: score.clamp(0, 100).toInt(),
      updatedAt: updatedAt ?? DateTime.now(),
    ).toJson();

    entry['components'] = components;
    entry['updatedAt'] = (updatedAt ?? DateTime.now()).toIso8601String();
    models[model.id] = entry;

    root = <String, dynamic>{
      'version': 2,
      'models': models,
    };
    await _preferences.setString(_storageKey, jsonEncode(root));
  }

  static String fingerprintFor(AiModel model) => <Object?>[
        model.effectiveRuntimeModelId,
        model.fileName,
        model.sizeBytes,
        model.version,
        model.source,
      ].join('|');
}
