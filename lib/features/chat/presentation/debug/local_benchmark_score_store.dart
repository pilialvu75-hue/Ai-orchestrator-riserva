import 'dart:convert';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';

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

    const weights = <LocalBenchmarkComponent, int>{
      LocalBenchmarkComponent.quick: 10,
      LocalBenchmarkComponent.quality: 25,
      LocalBenchmarkComponent.performance: 15,
      LocalBenchmarkComponent.vulkan: 10,
      LocalBenchmarkComponent.thermal: 10,
      LocalBenchmarkComponent.memoryContext: 10,
      LocalBenchmarkComponent.multilingual: 10,
      LocalBenchmarkComponent.stability: 10,
    };

    var weighted = 0;
    var totalWeight = 0;
    for (final entry in components.entries) {
      final weight = weights[entry.key] ?? 0;
      if (weight <= 0) continue;
      weighted += entry.value.score * weight;
      totalWeight += weight;
    }
    if (totalWeight == 0) return null;
    return (weighted / totalWeight).round().clamp(0, 100).toInt();
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
}

class LocalBenchmarkScoreStore {
  LocalBenchmarkScoreStore(this._preferences);

  static const String _storageKey = 'debug_local_benchmark_scores_v1';

  final PreferencesService _preferences;

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

    final output = <String, LocalModelBenchmarkScore>{};
    for (final model in models) {
      final entry = modelMap[model.id];
      if (entry is! Map) continue;

      final fingerprint = entry['fingerprint'];
      if (fingerprint != fingerprintFor(model)) continue;

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
    final existing = models[model.id];
    Map<String, dynamic> entry;
    if (existing is Map && existing['fingerprint'] == fingerprint) {
      entry = Map<String, dynamic>.from(existing);
    } else {
      entry = <String, dynamic>{
        'modelId': model.id,
        'fingerprint': fingerprint,
        'components': <String, dynamic>{},
      };
    }

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
      'version': 1,
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
