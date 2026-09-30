import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/diagnostics/github_diagnostics.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

typedef LocalModelBenchmarkProgress = void Function(String message);

class LocalModelBenchmarkCase {
  const LocalModelBenchmarkCase({
    required this.id,
    required this.prompt,
    this.context = const <ChatTurn>[],
    this.requiredAnyGroups = const <List<String>>[],
    this.forbiddenPhrases = const <String>[],
    this.exactAnswers = const <String>[],
  });

  final String id;
  final String prompt;
  final List<ChatTurn> context;
  final List<List<String>> requiredAnyGroups;
  final List<String> forbiddenPhrases;
  final List<String> exactAnswers;

  int get maxScore =>
      requiredAnyGroups.length + (exactAnswers.isEmpty ? 0 : 1);

  int score(String response) {
    final normalized = response.trim().toLowerCase();
    final exactNormalized = normalized
        .replaceFirst(RegExp(r'[.!?]+$'), '')
        .trim();
    var score = 0;

    for (final group in requiredAnyGroups) {
      if (group.any((candidate) => normalized.contains(candidate.toLowerCase()))) {
        score++;
      }
    }

    if (exactAnswers.isNotEmpty &&
        exactAnswers.any(
          (answer) => exactNormalized == answer.trim().toLowerCase(),
        )) {
      score++;
    }

    for (final forbidden in forbiddenPhrases) {
      if (normalized.contains(forbidden.toLowerCase())) {
        score--;
      }
    }

    return score.clamp(0, maxScore).toInt();
  }

  int forbiddenHits(String response) {
    final normalized = response.trim().toLowerCase();
    return forbiddenPhrases
        .where((phrase) => normalized.contains(phrase.toLowerCase()))
        .length;
  }
}

class LocalModelBenchmarkCaseResult {
  const LocalModelBenchmarkCaseResult({
    required this.caseId,
    required this.response,
    required this.score,
    required this.maxScore,
    required this.forbiddenHits,
    required this.firstContentMs,
    required this.totalMs,
    required this.reportedTokens,
    required this.prefillMs,
    required this.observedGpuLayers,
    required this.observedBatch,
    required this.observedMicroBatch,
    this.observedContext = 0,
    required this.startPressure,
    required this.endPressure,
    required this.startAvailableBytes,
    required this.endAvailableBytes,
    required this.startBatteryTemperatureDeciC,
    required this.endBatteryTemperatureDeciC,
    required this.sessionStart,
    required this.sessionEnd,
  });

  final String caseId;
  final String response;
  final int score;
  final int maxScore;
  final int forbiddenHits;
  final int firstContentMs;
  final int totalMs;
  final int reportedTokens;
  final int prefillMs;
  final int observedGpuLayers;
  final int observedBatch;
  final int observedMicroBatch;
  final int observedContext;
  final String startPressure;
  final String endPressure;
  final int? startAvailableBytes;
  final int? endAvailableBytes;
  final int? startBatteryTemperatureDeciC;
  final int? endBatteryTemperatureDeciC;
  final String sessionStart;
  final String sessionEnd;

  double get decodeTokensPerSecond {
    final decodeMs = totalMs - firstContentMs;
    if (decodeMs <= 0 || reportedTokens <= 0) return 0;
    return reportedTokens * 1000 / decodeMs;
  }
}

class LocalModelBenchmarkModelResult {
  const LocalModelBenchmarkModelResult({
    required this.modelId,
    required this.displayName,
    required this.cases,
    this.catalogModelId,
  });

  final String modelId;
  final String displayName;
  final String? catalogModelId;
  final List<LocalModelBenchmarkCaseResult> cases;

  int get score => cases.fold<int>(0, (sum, item) => sum + item.score);

  int get maxScore =>
      cases.fold<int>(0, (sum, item) => sum + item.maxScore);

  double get averageFirstContentMs => cases.isEmpty
      ? 0
      : cases.fold<int>(0, (sum, item) => sum + item.firstContentMs) /
          cases.length;

  double get averageTotalMs => cases.isEmpty
      ? 0
      : cases.fold<int>(0, (sum, item) => sum + item.totalMs) / cases.length;

  double get averagePrefillMs {
    final valid = cases
        .map((item) => item.prefillMs)
        .where((value) => value >= 0)
        .toList(growable: false);
    if (valid.isEmpty) return 0;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  double? get maxBatteryTemperatureC {
    final readings = <int>[
      for (final item in cases)
        if (item.startBatteryTemperatureDeciC != null)
          item.startBatteryTemperatureDeciC!,
      for (final item in cases)
        if (item.endBatteryTemperatureDeciC != null)
          item.endBatteryTemperatureDeciC!,
    ];
    if (readings.isEmpty) return null;
    return readings.reduce((a, b) => a > b ? a : b) / 10.0;
  }

  double? get batteryTemperatureDeltaC {
    final starts = cases
        .map((item) => item.startBatteryTemperatureDeciC)
        .whereType<int>()
        .toList(growable: false);
    final ends = cases
        .map((item) => item.endBatteryTemperatureDeciC)
        .whereType<int>()
        .toList(growable: false);
    if (starts.isEmpty || ends.isEmpty) return null;
    return (ends.last - starts.first) / 10.0;
  }

  double get averageDecodeTokensPerSecond {
    final valid = cases
        .map((item) => item.decodeTokensPerSecond)
        .where((value) => value > 0)
        .toList(growable: false);
    if (valid.isEmpty) return 0;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  bool? get repeatedSddOutcomeConsistent {
    LocalModelBenchmarkCaseResult? first;
    LocalModelBenchmarkCaseResult? repeat;
    for (final item in cases) {
      if (item.caseId == 'sdd_typo_first') first = item;
      if (item.caseId == 'sdd_repeat_empty') repeat = item;
    }
    if (first == null || repeat == null) return null;
    return _mentionsSsd(first.response) == _mentionsSsd(repeat.response);
  }

  static bool _mentionsSsd(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('ssd') ||
        normalized.contains('solid-state') ||
        normalized.contains('stato solido');
  }
}

class LocalModelBenchmarkFailure {
  const LocalModelBenchmarkFailure({
    required this.modelId,
    required this.catalogModelId,
    required this.displayName,
    required this.error,
  });

  final String modelId;
  final String catalogModelId;
  final String displayName;
  final String error;
}

class LocalModelBenchmarkCriticalResourceException implements Exception {
  const LocalModelBenchmarkCriticalResourceException(this.message);

  final String message;

  @override
  String toString() => message;
}
class LocalModelBenchmarkReport {
  const LocalModelBenchmarkReport({
    required this.createdAt,
    required this.models,
    this.failures = const <LocalModelBenchmarkFailure>[],
  });

  final DateTime createdAt;
  final List<LocalModelBenchmarkModelResult> models;
  final List<LocalModelBenchmarkFailure> failures;

  String toPlainText({bool includeResponses = true}) {
    final buffer = StringBuffer()
      ..writeln('LOCAL MODEL BENCHMARK')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln('order=${models.map((item) => item.modelId).join(' -> ')}')
      ..writeln();

    for (final model in models) {
      buffer
        ..writeln('${model.displayName} [${model.modelId}]')
        ..writeln('quality=${model.score}/${model.maxScore}')
        ..writeln(
          'avg_first_content_ms=${model.averageFirstContentMs.toStringAsFixed(0)}',
        )
        ..writeln('avg_total_ms=${model.averageTotalMs.toStringAsFixed(0)}')
        ..writeln('avg_prefill_ms=${model.averagePrefillMs.toStringAsFixed(0)}')
        ..writeln(
          'avg_decode_tokens_s=${model.averageDecodeTokensPerSecond.toStringAsFixed(2)}',
        )
        ..writeln(
          'max_battery_temp_c=${model.maxBatteryTemperatureC?.toStringAsFixed(1) ?? 'n/a'}',
        )
        ..writeln(
          'battery_temp_delta_c=${model.batteryTemperatureDeltaC?.toStringAsFixed(1) ?? 'n/a'}',
        )
        ..writeln(
          'sdd_repeat_consistent=${model.repeatedSddOutcomeConsistent ?? 'n/a'}',
        );

      for (final item in model.cases) {
        buffer.writeln(
          '- ${item.caseId}: score=${item.score}/${item.maxScore} '
          'forbidden=${item.forbiddenHits} '
          'first=${item.firstContentMs}ms total=${item.totalMs}ms '
          'prefill=${item.prefillMs}ms '
          'tokens=${item.reportedTokens} '
          'decode=${item.decodeTokensPerSecond.toStringAsFixed(2)}tok/s '
          'gpu=${item.observedGpuLayers} '
          'ctx=${item.observedContext} '
          'batch=${item.observedBatch}/${item.observedMicroBatch} '
          'pressure=${item.startPressure}->${item.endPressure} '
          'battery_temp_c='
          '${item.startBatteryTemperatureDeciC == null ? 'n/a' : (item.startBatteryTemperatureDeciC! / 10).toStringAsFixed(1)}'
          '->'
          '${item.endBatteryTemperatureDeciC == null ? 'n/a' : (item.endBatteryTemperatureDeciC! / 10).toStringAsFixed(1)} '
          'session=${item.sessionStart}->${item.sessionEnd}',
        );
        if (includeResponses) {
          buffer.writeln('  response=${item.response.replaceAll('\n', ' ')}');
        }
      }
      buffer.writeln();
    }

    if (failures.isNotEmpty) {
      buffer.writeln('failures:');
      for (final failure in failures) {
        buffer.writeln(
          '- ${failure.displayName} [${failure.modelId}]: ${failure.error}',
        );
      }
    }

    return buffer.toString().trimRight();
  }
}

enum LocalModelPerformancePhase { cold, warm }

class LocalModelPerformanceSample {
  const LocalModelPerformanceSample({
    required this.phase,
    required this.repetition,
    required this.result,
  });

  final LocalModelPerformancePhase phase;
  final int repetition;
  final LocalModelBenchmarkCaseResult result;
}

class LocalModelPerformanceModelResult {
  const LocalModelPerformanceModelResult({
    required this.modelId,
    required this.catalogModelId,
    required this.displayName,
    required this.samples,
  });

  final String modelId;
  final String catalogModelId;
  final String displayName;
  final List<LocalModelPerformanceSample> samples;

  LocalModelPerformanceSample? get coldSample {
    for (final sample in samples) {
      if (sample.phase == LocalModelPerformancePhase.cold) return sample;
    }
    return null;
  }

  List<LocalModelPerformanceSample> get warmSamples => samples
      .where((sample) => sample.phase == LocalModelPerformancePhase.warm)
      .toList(growable: false);

  double get averageWarmFirstContentMs => _warmAverage(
        (sample) => sample.result.firstContentMs.toDouble(),
      );

  double get averageWarmPrefillMs => _warmAverage(
        (sample) => sample.result.prefillMs.toDouble(),
        ignoreNegative: true,
      );

  double get averageWarmTotalMs => _warmAverage(
        (sample) => sample.result.totalMs.toDouble(),
      );

  double get averageWarmDecodeTokensPerSecond => _warmAverage(
        (sample) => sample.result.decodeTokensPerSecond,
      );

  bool get coldSessionConfirmed => coldSample?.result.sessionStart == 'cold';

  bool get warmSessionConfirmed {
    final warm = warmSamples;
    return warm.isNotEmpty &&
        warm.every((sample) => sample.result.sessionStart == 'warm');
  }

  double _warmAverage(
    double Function(LocalModelPerformanceSample sample) valueOf, {
    bool ignoreNegative = false,
  }) {
    final values = warmSamples
        .map(valueOf)
        .where((value) => !ignoreNegative || value >= 0)
        .toList(growable: false);
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }
}

class LocalModelPerformanceReport {
  const LocalModelPerformanceReport({
    required this.createdAt,
    required this.models,
    this.failures = const <LocalModelBenchmarkFailure>[],
  });

  final DateTime createdAt;
  final List<LocalModelPerformanceModelResult> models;
  final List<LocalModelBenchmarkFailure> failures;

  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('LOCAL MODEL PERFORMANCE BENCHMARK')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln();

    for (final model in models) {
      final cold = model.coldSample?.result;
      buffer
        ..writeln('${model.displayName} [${model.modelId}]')
        ..writeln(
          'cold_first_ms=${cold?.firstContentMs ?? -1} '
          'cold_prefill_ms=${cold?.prefillMs ?? -1} '
          'cold_total_ms=${cold?.totalMs ?? -1} '
          'cold_decode_tokens_s='
          '${cold?.decodeTokensPerSecond.toStringAsFixed(2) ?? 'n/a'}',
        )
        ..writeln(
          'warm_first_ms='
          '${model.averageWarmFirstContentMs.toStringAsFixed(0)} '
          'warm_prefill_ms=${model.averageWarmPrefillMs.toStringAsFixed(0)} '
          'warm_total_ms=${model.averageWarmTotalMs.toStringAsFixed(0)} '
          'warm_decode_tokens_s='
          '${model.averageWarmDecodeTokensPerSecond.toStringAsFixed(2)}',
        )
        ..writeln(
          'cold_session_confirmed=${model.coldSessionConfirmed} '
          'warm_session_confirmed=${model.warmSessionConfirmed}',
        )
        ..writeln();
    }

    if (failures.isNotEmpty) {
      buffer.writeln('failures:');
      for (final failure in failures) {
        buffer.writeln(
          '- ${failure.displayName} [${failure.modelId}]: ${failure.error}',
        );
      }
    }

    return buffer.toString().trimRight();
  }
}

class LocalModelMemoryContextSample {
  const LocalModelMemoryContextSample({
    required this.levelId,
    required this.targetCharacters,
    required this.recovery,
    required this.result,
  });

  final String levelId;
  final int targetCharacters;
  final bool recovery;
  final LocalModelBenchmarkCaseResult result;

  bool get passed =>
      result.maxScore > 0 && result.score == result.maxScore;
}

class LocalModelMemoryContextModelResult {
  const LocalModelMemoryContextModelResult({
    required this.modelId,
    required this.catalogModelId,
    required this.displayName,
    required this.samples,
    required this.stoppedEarly,
    this.stopReason,
  });

  final String modelId;
  final String catalogModelId;
  final String displayName;
  final List<LocalModelMemoryContextSample> samples;
  final bool stoppedEarly;
  final String? stopReason;

  Iterable<LocalModelMemoryContextSample> get contextSamples =>
      samples.where((sample) => !sample.recovery);

  LocalModelMemoryContextSample? get recoverySample {
    for (final sample in samples.reversed) {
      if (sample.recovery) return sample;
    }
    return null;
  }

  int get passedContextLevels =>
      contextSamples.where((sample) => sample.passed).length;

  int get attemptedContextLevels => contextSamples.length;

  bool get recoveryPassed => recoverySample?.passed == true;

  int get maxObservedContext {
    var value = 0;
    for (final sample in samples) {
      if (sample.result.observedContext > value) {
        value = sample.result.observedContext;
      }
    }
    return value;
  }

  int? get minimumAvailableBytes {
    final values = <int>[
      for (final sample in samples)
        if (sample.result.startAvailableBytes != null)
          sample.result.startAvailableBytes!,
      for (final sample in samples)
        if (sample.result.endAvailableBytes != null)
          sample.result.endAvailableBytes!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  String get worstPressure {
    var sawKnown = false;
    var sawHigh = false;
    for (final sample in samples) {
      for (final pressure in <String>[
        sample.result.startPressure,
        sample.result.endPressure,
      ]) {
        if (pressure == 'critical') return 'critical';
        if (pressure == 'high') {
          sawKnown = true;
          sawHigh = true;
        } else if (pressure == 'normal') {
          sawKnown = true;
        }
      }
    }
    if (sawHigh) return 'high';
    return sawKnown ? 'normal' : 'unknown';
  }
}

class LocalModelMemoryContextReport {
  const LocalModelMemoryContextReport({
    required this.createdAt,
    required this.models,
    this.failures = const <LocalModelBenchmarkFailure>[],
  });

  final DateTime createdAt;
  final List<LocalModelMemoryContextModelResult> models;
  final List<LocalModelBenchmarkFailure> failures;

  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('LOCAL MODEL MEMORY / CONTEXT BENCHMARK')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln();

    for (final model in models) {
      buffer
        ..writeln('${model.displayName} [${model.modelId}]')
        ..writeln(
          'context_passed=${model.passedContextLevels}/'
          '${LocalModelBenchmarkRunner.memoryContextTargetCharacters.length} '
          'recovery_passed=${model.recoveryPassed} '
          'max_observed_ctx=${model.maxObservedContext} '
          'worst_pressure=${model.worstPressure} '
          'min_available_bytes=${model.minimumAvailableBytes ?? -1} '
          'stopped_early=${model.stoppedEarly} '
          'stop_reason=${model.stopReason ?? 'none'}',
        );

      for (final sample in model.samples) {
        final result = sample.result;
        buffer.writeln(
          '- level=${sample.levelId} '
          'target_chars=${sample.targetCharacters} '
          'recovery=${sample.recovery} '
          'passed=${sample.passed} '
          'ctx=${result.observedContext} '
          'prefill=${result.prefillMs}ms '
          'first=${result.firstContentMs}ms '
          'pressure=${result.startPressure}->${result.endPressure} '
          'available=${result.startAvailableBytes ?? -1}->'
          '${result.endAvailableBytes ?? -1}',
        );
      }
      buffer.writeln();
    }

    if (failures.isNotEmpty) {
      buffer.writeln('failures:');
      for (final failure in failures) {
        buffer.writeln(
          '- ${failure.displayName} [${failure.modelId}]: ${failure.error}',
        );
      }
    }

    return buffer.toString().trimRight();
  }
}

class LocalModelThermalSample {
  const LocalModelThermalSample({
    required this.repetition,
    required this.result,
  });

  final int repetition;
  final LocalModelBenchmarkCaseResult result;
}

class LocalModelThermalModelResult {
  const LocalModelThermalModelResult({
    required this.modelId,
    required this.catalogModelId,
    required this.displayName,
    required this.baselineBatteryTemperatureDeciC,
    required this.samples,
    required this.stoppedEarly,
    this.stopReason,
  });

  final String modelId;
  final String catalogModelId;
  final String displayName;
  final int? baselineBatteryTemperatureDeciC;
  final List<LocalModelThermalSample> samples;
  final bool stoppedEarly;
  final String? stopReason;

  bool get thermalTelemetryComplete =>
      baselineBatteryTemperatureDeciC != null &&
      samples.isNotEmpty &&
      samples.every(
        (sample) => sample.result.endBatteryTemperatureDeciC != null,
      );

  double? get baselineBatteryTemperatureC =>
      baselineBatteryTemperatureDeciC == null
          ? null
          : baselineBatteryTemperatureDeciC! / 10.0;

  double? get maxBatteryTemperatureC {
    if (!thermalTelemetryComplete) return null;
    var maxDeciC = baselineBatteryTemperatureDeciC!;
    for (final sample in samples) {
      final start = sample.result.startBatteryTemperatureDeciC;
      final end = sample.result.endBatteryTemperatureDeciC;
      if (start != null && start > maxDeciC) maxDeciC = start;
      if (end != null && end > maxDeciC) maxDeciC = end;
    }
    return maxDeciC / 10.0;
  }

  double? get batteryTemperatureRiseC {
    final baseline = baselineBatteryTemperatureC;
    final maxTemp = maxBatteryTemperatureC;
    if (baseline == null || maxTemp == null) return null;
    return maxTemp - baseline;
  }

  double get decodeRetention {
    final first = _windowAverage(
      samples.take(3).map((sample) => sample.result.decodeTokensPerSecond),
    );
    final last = _windowAverage(
      samples.reversed
          .take(3)
          .map((sample) => sample.result.decodeTokensPerSecond),
    );
    if (first <= 0) return 0;
    return last / first;
  }

  double get firstContentSlowdown {
    final first = _windowAverage(
      samples.take(3).map(
            (sample) => sample.result.firstContentMs.toDouble(),
          ),
    );
    final last = _windowAverage(
      samples.reversed.take(3).map(
            (sample) => sample.result.firstContentMs.toDouble(),
          ),
    );
    if (first <= 0) return double.infinity;
    return last / first;
  }

  static double _windowAverage(Iterable<double> values) {
    final list = values.where((value) => value.isFinite).toList(growable: false);
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }
}

class LocalModelThermalReport {
  const LocalModelThermalReport({
    required this.createdAt,
    required this.models,
    this.failures = const <LocalModelBenchmarkFailure>[],
  });

  final DateTime createdAt;
  final List<LocalModelThermalModelResult> models;
  final List<LocalModelBenchmarkFailure> failures;

  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('LOCAL MODEL THERMAL STRESS')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln(
        'thermal_source=Android battery temperature proxy '
        '(not SoC junction temperature)',
      )
      ..writeln();

    for (final model in models) {
      buffer
        ..writeln('${model.displayName} [${model.modelId}]')
        ..writeln(
          'baseline_temp_c='
          '${model.baselineBatteryTemperatureC?.toStringAsFixed(1) ?? 'n/a'} '
          'max_temp_c='
          '${model.maxBatteryTemperatureC?.toStringAsFixed(1) ?? 'n/a'} '
          'rise_c='
          '${model.batteryTemperatureRiseC?.toStringAsFixed(1) ?? 'n/a'}',
        )
        ..writeln(
          'decode_retention='
          '${model.decodeRetention.toStringAsFixed(2)} '
          'first_content_slowdown='
          '${model.firstContentSlowdown.isFinite ? model.firstContentSlowdown.toStringAsFixed(2) : 'n/a'}',
        )
        ..writeln(
          'completed_repetitions=${model.samples.length} '
          'stopped_early=${model.stoppedEarly} '
          'stop_reason=${model.stopReason ?? 'none'}',
        );

      for (final sample in model.samples) {
        final result = sample.result;
        buffer.writeln(
          '- run=${sample.repetition} '
          'first=${result.firstContentMs}ms '
          'prefill=${result.prefillMs}ms '
          'total=${result.totalMs}ms '
          'decode=${result.decodeTokensPerSecond.toStringAsFixed(2)}tok/s '
          'pressure=${result.startPressure}->${result.endPressure} '
          'battery_temp_c='
          '${result.startBatteryTemperatureDeciC == null ? 'n/a' : (result.startBatteryTemperatureDeciC! / 10).toStringAsFixed(1)}'
          '->'
          '${result.endBatteryTemperatureDeciC == null ? 'n/a' : (result.endBatteryTemperatureDeciC! / 10).toStringAsFixed(1)}',
        );
      }
      buffer.writeln();
    }

    if (failures.isNotEmpty) {
      buffer.writeln('failures:');
      for (final failure in failures) {
        buffer.writeln(
          '- ${failure.displayName} [${failure.modelId}]: ${failure.error}',
        );
      }
    }

    return buffer.toString().trimRight();
  }
}

class VulkanLayerSweepSample {
  const VulkanLayerSweepSample({
    required this.requestedGpuLayers,
    required this.modelId,
    required this.displayName,
    required this.repetition,
    required this.result,
  });

  final int requestedGpuLayers;
  final String modelId;
  final String displayName;
  final int repetition;
  final LocalModelBenchmarkCaseResult result;
}

class VulkanLayerSweepReport {
  const VulkanLayerSweepReport({
    required this.createdAt,
    required this.samples,
  });

  final DateTime createdAt;
  final List<VulkanLayerSweepSample> samples;

  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('VULKAN GPU LAYER SWEEP')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln('profiles=0 -> 10 -> 99')
      ..writeln('production_default=${LlamaNativeDefaults.nGpuLayers}')
      ..writeln(
        'thermal_source=Android battery temperature proxy (not SoC junction temperature)',
      )
      ..writeln();

    for (final sample in samples) {
      final result = sample.result;
      buffer.writeln(
        '- requested=${sample.requestedGpuLayers} '
        'observed=${result.observedGpuLayers} '
        'model=${sample.modelId} '
        'run=${sample.repetition} '
        'first=${result.firstContentMs}ms '
        'prefill=${result.prefillMs}ms '
        'total=${result.totalMs}ms '
        'decode=${result.decodeTokensPerSecond.toStringAsFixed(2)}tok/s '
        'pressure=${result.startPressure}->${result.endPressure} '
        'available=${result.startAvailableBytes ?? -1}->'
        '${result.endAvailableBytes ?? -1} '
        'battery_temp_c='
        '${result.startBatteryTemperatureDeciC == null ? 'n/a' : (result.startBatteryTemperatureDeciC! / 10).toStringAsFixed(1)}'
        '->'
        '${result.endBatteryTemperatureDeciC == null ? 'n/a' : (result.endBatteryTemperatureDeciC! / 10).toStringAsFixed(1)} '
        'session=${result.sessionStart}->${result.sessionEnd}',
      );
    }
    return buffer.toString().trimRight();
  }
}

class LocalModelBenchmarkRunner {
  LocalModelBenchmarkRunner({
    required LocalRuntimeProvider runtimeProvider,
    required LocalAiRepository localAiRepository,
    ResourceMonitor? resourceMonitor,
  })  : _runtimeProvider = runtimeProvider,
        _localAiRepository = localAiRepository,
        _resourceMonitor = resourceMonitor ?? ResourceMonitor.instance;

  static const int _maxTokens = 96;
  static const double _temperature = 0.5;
  static const Duration _betweenCases = Duration(milliseconds: 350);
  static const List<int> vulkanSweepProfiles = <int>[0, 10, 99];
  static const int vulkanSweepRepetitions = 2;

  static const List<String> defaultOrchestratorTargetModelIds = <String>[
    LocalInferenceModelIds.phi35Mini,
    LocalInferenceModelIds.nemotron3Nano4b,
  ];

  static bool isRunnableCandidate(AiModel model) =>
      model.isDownloaded &&
      (model.localPath?.trim().isNotEmpty ?? false) &&
      (model.validationStatus == ModelValidationStatus.validatedOk ||
          model.validationStatus == ModelValidationStatus.updateAvailable);

  static const List<LocalModelBenchmarkCase> cases =
      <LocalModelBenchmarkCase>[
    LocalModelBenchmarkCase(
      id: 'sdd_typo_first',
      prompt: 'cosa è sdd',
      requiredAnyGroups: <List<String>>[
        <String>['ssd', 'solid-state', 'stato solido'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'vulkan_fact',
      prompt:
          'Che cos\'è Vulkan e chi lo standardizza? Rispondi in una frase.',
      requiredAnyGroups: <List<String>>[
        <String>['api'],
        <String>['khronos'],
      ],
      forbiddenPhrases: <String>[
        'linguaggio di programmazione',
        'progettato da google',
        'sviluppato da google',
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'ram_fact',
      prompt: 'A cosa serve la RAM? Rispondi in una frase.',
      requiredAnyGroups: <List<String>>[
        // "memori" matches both "memoria" and verbs such as "memorizza".
        <String>['memori'],
        <String>['tempor', 'volatile'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'arithmetic',
      prompt: 'Quanto fa 17 × 19? Rispondi solo con il numero.',
      requiredAnyGroups: <List<String>>[
        <String>['323'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'ssd_direct',
      prompt: 'Che cos\'è un SSD? Rispondi in una frase.',
      requiredAnyGroups: <List<String>>[
        <String>['ssd', 'solid-state', 'stato solido'],
        <String>['flash'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'sdd_repeat_empty',
      prompt: 'cosa è sdd',
      requiredAnyGroups: <List<String>>[
        <String>['ssd', 'solid-state', 'stato solido'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'sdd_after_history',
      prompt: 'cosa è sdd',
      context: <ChatTurn>[
        ChatTurn(
          role: ChatRole.user,
          content: 'cosa è sdd',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content:
              '"sdd" non è un termine o acronimo chiaro. Fornisci più contesto.',
        ),
        ChatTurn(
          role: ChatRole.user,
          content: 'cosa Vulkan',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content:
              'Vulkan è un API grafica e compute standardizzata dal Khronos Group.',
        ),
      ],
      requiredAnyGroups: <List<String>>[
        <String>['ssd', 'solid-state', 'stato solido'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'ssd_hdd_followup',
      prompt: 'E rispetto a un HDD?',
      context: <ChatTurn>[
        ChatTurn(
          role: ChatRole.user,
          content: 'Che cos\'è un SSD?',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content:
              'Un SSD è un\'unità di archiviazione a stato solido basata su memoria flash.',
        ),
      ],
      requiredAnyGroups: <List<String>>[
        <String>['veloc'],
        <String>['meccanic', 'parti mobili', 'magnetic'],
      ],
    ),
  ];

  static List<LocalModelBenchmarkCase> get quickCases {
    const ids = <String>{
      'vulkan_fact',
      'ram_fact',
      'arithmetic',
      'ssd_hdd_followup',
    };
    return cases.where((item) => ids.contains(item.id)).toList(growable: false);
  }

  static const List<LocalModelBenchmarkCase> qualityCases =
      <LocalModelBenchmarkCase>[
    LocalModelBenchmarkCase(
      id: 'quality_fact_planet',
      prompt:
          'Quale pianeta è conosciuto come Pianeta Rosso? '
          'Rispondi solo con il nome del pianeta.',
      requiredAnyGroups: <List<String>>[
        <String>['marte', 'mars'],
      ],
      exactAnswers: <String>['marte', 'mars'],
      forbiddenPhrases: <String>['giove', 'jupiter', 'venere', 'venus'],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_fact_water',
      prompt:
          'A livello del mare, a quale temperatura bolle '
          'approssimativamente l\'acqua? Rispondi in una frase breve.',
      requiredAnyGroups: <List<String>>[
        <String>['100'],
        <String>['celsius', '°c', 'gradi'],
      ],
      forbiddenPhrases: <String>['90 °c', '80 °c', '212 °c'],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_instruction_arithmetic',
      prompt: 'Quanto fa 14 + 28? Rispondi solo con il numero.',
      requiredAnyGroups: <List<String>>[
        <String>['42'],
      ],
      exactAnswers: <String>['42'],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_context_license',
      prompt:
          'Quale licenza usa il progetto Aurora? '
          'Rispondi solo con la sigla.',
      context: <ChatTurn>[
        ChatTurn(
          role: ChatRole.user,
          content:
              'Nota per questa conversazione: il progetto Aurora usa '
              'la licenza MIT.',
        ),
        ChatTurn(
          role: ChatRole.assistant,
          content: 'Ricevuto: Aurora usa la licenza MIT.',
        ),
      ],
      requiredAnyGroups: <List<String>>[
        <String>['mit'],
      ],
      exactAnswers: <String>['mit'],
      forbiddenPhrases: <String>['apache', 'gpl'],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_hallucination_unknown',
      prompt:
          'La parola inventata "trulvex" non ha un significato stabilito. '
          'Se ti chiedo cos\'è trulvex, rispondi in una frase senza '
          'inventare una definizione.',
      requiredAnyGroups: <List<String>>[
        <String>[
          'inventata',
          'non ha un significato',
          'nessun significato',
          'non esiste',
          'non è definita',
          'senza contesto',
        ],
      ],
      forbiddenPhrases: <String>[
        'protocollo di rete',
        'linguaggio di programmazione',
        'sistema operativo',
        'database distribuito',
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_logic_deduction',
      prompt:
          'Tutti gli zorbi sono blu. Lio è uno zorbo. '
          'Di che colore è Lio? Rispondi solo con il colore.',
      requiredAnyGroups: <List<String>>[
        <String>['blu', 'blue'],
      ],
      exactAnswers: <String>['blu', 'blue'],
      forbiddenPhrases: <String>['rosso', 'red', 'verde', 'green'],
    ),
    LocalModelBenchmarkCase(
      id: 'quality_exact_instruction',
      prompt:
          'Rispondi esattamente con queste tre parole, senza aggiungere '
          'altro: cielo mare vento',
      exactAnswers: <String>['cielo mare vento'],
    ),
  ];

  static const List<LocalModelBenchmarkCase> multilingualCases =
      <LocalModelBenchmarkCase>[
    LocalModelBenchmarkCase(
      id: 'multilingual_it_exact',
      prompt:
          'Rispondi esattamente con queste due parole, senza aggiungere '
          'altro: cielo blu',
      exactAnswers: <String>['cielo blu'],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_it_fact',
      prompt:
          'Di che colore è normalmente la neve? '
          'Rispondi con una sola parola in italiano.',
      requiredAnyGroups: <List<String>>[
        <String>['bianca', 'bianco'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_en_exact',
      prompt:
          'Reply with exactly these two words and nothing else: blue sky',
      exactAnswers: <String>['blue sky'],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_en_fact',
      prompt:
          'What color is snow normally? Answer with one English word.',
      requiredAnyGroups: <List<String>>[
        <String>['white'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_fr_exact',
      prompt:
          'Réponds exactement avec ces deux mots, sans rien ajouter : '
          'ciel bleu',
      exactAnswers: <String>['ciel bleu'],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_fr_fact',
      prompt:
          'De quelle couleur est normalement la neige ? '
          'Réponds avec un seul mot en français.',
      requiredAnyGroups: <List<String>>[
        <String>['blanche', 'blanc'],
      ],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_es_exact',
      prompt:
          'Responde exactamente con estas dos palabras, sin añadir nada: '
          'cielo azul',
      exactAnswers: <String>['cielo azul'],
    ),
    LocalModelBenchmarkCase(
      id: 'multilingual_es_fact',
      prompt:
          '¿De qué color es normalmente la nieve? '
          'Responde con una sola palabra en español.',
      requiredAnyGroups: <List<String>>[
        <String>['blanca', 'blanco'],
      ],
    ),
  ];

  static const List<String> multilingualLanguages =
      <String>['it', 'en', 'fr', 'es'];

  static const LocalModelBenchmarkCase performanceCase =
      LocalModelBenchmarkCase(
    id: 'performance_generation',
    prompt:
        'Scrivi circa 70 parole in italiano su come la memoria RAM aiuta '
        'un computer durante l\'uso quotidiano. Usa testo continuo, '
        'senza elenco.',
  );

  static const int performanceWarmRepetitions = 2;
  static const int thermalStressRepetitions = 10;
  static const List<int> memoryContextTargetCharacters = <int>[
    1200,
    3600,
    7200,
    11000,
  ];
  static const String memoryContextMarkerPrefix = 'ORCH-MEM';
  static const LocalModelBenchmarkCase memoryContextRecoveryCase =
      LocalModelBenchmarkCase(
    id: 'memory_context_recovery',
    prompt: 'Rispondi con la parola RECOVERY-OK.',
    requiredAnyGroups: <List<String>>[
      <String>['recovery-ok'],
    ],
  );
  static const int thermalStartMaxBatteryTemperatureDeciC = 420;
  static const int thermalStopBatteryTemperatureDeciC = 450;
  static const int thermalMaxRiseDeciC = 80;
  static const Duration thermalBetweenCases = Duration(milliseconds: 500);

  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;
  final ResourceMonitor _resourceMonitor;

  static LocalModelBenchmarkCase memoryContextCaseFor({
    required int levelIndex,
    required int targetCharacters,
  }) {
    final marker = '$memoryContextMarkerPrefix-${levelIndex + 1}-Q7';
    final context = <ChatTurn>[
      ChatTurn(
        role: ChatRole.user,
        content:
            'Memorizza questo codice e conservalo fino alla domanda finale: '
            '$marker',
      ),
      ChatTurn(
        role: ChatRole.assistant,
        content: 'Codice memorizzato.',
      ),
    ];

    var characters = context.fold<int>(
      0,
      (sum, turn) => sum + turn.content.length,
    );
    var block = 1;
    while (characters < targetCharacters) {
      final userText =
          'Blocco $block di contesto. Questo testo serve esclusivamente a '
          'riempire in modo controllato la finestra di memoria del modello. '
          'Contiene informazioni ordinarie su attività quotidiane, strumenti, '
          'documenti e numeri non correlati al codice segreto. Numero blocco: '
          '$block. Mantieni il contesto senza inventare collegamenti.';
      final assistantText =
          'Ricevuto il blocco $block. Continuo a conservare il contesto '
          'precedente senza modificarne i dettagli.';
      context
        ..add(ChatTurn(role: ChatRole.user, content: userText))
        ..add(ChatTurn(role: ChatRole.assistant, content: assistantText));
      characters += userText.length + assistantText.length;
      block++;
    }

    return LocalModelBenchmarkCase(
      id: 'memory_context_${targetCharacters}_chars',
      prompt:
          'Qual era il codice che ti ho chiesto di memorizzare all’inizio? '
          'Rispondi con il codice.',
      context: List<ChatTurn>.unmodifiable(context),
      requiredAnyGroups: <List<String>>[
        <String>[marker.toLowerCase()],
      ],
    );
  }

  Future<List<AiModel>> loadBenchmarkCandidates() async {
    final availableResult = await _localAiRepository.getAvailableModels();
    final available = availableResult.fold<List<AiModel>>(
      (failure) => throw StateError(
        'Model catalogue lookup failed: ${failure.message}',
      ),
      (models) => List<AiModel>.of(models),
    );

    available.sort((a, b) {
      final runnableOrder =
          (isRunnableCandidate(a) ? 0 : 1) - (isRunnableCandidate(b) ? 0 : 1);
      if (runnableOrder != 0) return runnableOrder;

      final sizeOrder = a.sizeBytes.compareTo(b.sizeBytes);
      if (sizeOrder != 0) return sizeOrder;

      return a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          );
    });

    return List<AiModel>.unmodifiable(available);
  }

  Future<LocalModelBenchmarkReport> run({
    LocalModelBenchmarkProgress? onProgress,
    Iterable<String>? modelIds,
    Iterable<LocalModelBenchmarkCase>? benchmarkCases,
    bool continueOnModelError = false,
  }) async {
    final targets = await _resolveTargets(modelIds);
    final selectedCases = benchmarkCases?.toList(growable: false) ?? cases;

    if (selectedCases.isEmpty) {
      throw StateError('Benchmark requires at least one test case.');
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_BENCH_BEGIN] models=${targets.map((m) => m.effectiveRuntimeModelId).join(',')} '
      'cases=${selectedCases.length} max_tokens=$_maxTokens temperature=$_temperature',
    );

    final modelResults = <LocalModelBenchmarkModelResult>[];
    final failures = <LocalModelBenchmarkFailure>[];

    for (var modelIndex = 0; modelIndex < targets.length; modelIndex++) {
      final model = targets[modelIndex];

      try {
        final caseResults = <LocalModelBenchmarkCaseResult>[];

        RuntimeEventLog.instance.emit(
          '[LOCAL_MODEL_BENCH_MODEL_BEGIN] model=${model.effectiveRuntimeModelId} '
          'order=${modelIndex + 1}/${targets.length}',
        );

        for (var caseIndex = 0;
            caseIndex < selectedCases.length;
            caseIndex++) {
          final benchmarkCase = selectedCases[caseIndex];
          onProgress?.call(
            '${model.displayName} ${caseIndex + 1}/${selectedCases.length}',
          );

          final result = await _runCase(
            model: model,
            benchmarkCase: benchmarkCase,
          );
          caseResults.add(result);

          RuntimeEventLog.instance.emit(
            '[LOCAL_MODEL_BENCH_CASE] '
            'model=${model.effectiveRuntimeModelId} '
            'case=${benchmarkCase.id} '
            'score=${result.score}/${result.maxScore} '
            'forbidden_hits=${result.forbiddenHits} '
            'first_content_ms=${result.firstContentMs} '
            'total_ms=${result.totalMs} '
            'prefill_ms=${result.prefillMs} '
            'reported_tokens=${result.reportedTokens} '
            'decode_tokens_s=${result.decodeTokensPerSecond.toStringAsFixed(2)} '
            'gpu_layers=${result.observedGpuLayers} '
            'n_ctx=${result.observedContext} '
            'n_batch=${result.observedBatch} '
            'n_ubatch=${result.observedMicroBatch} '
            'pressure=${result.startPressure}->${result.endPressure} '
            'start_available_bytes=${result.startAvailableBytes ?? -1} '
            'end_available_bytes=${result.endAvailableBytes ?? -1} '
            'start_battery_temp_decic=${result.startBatteryTemperatureDeciC ?? -1} '
            'end_battery_temp_decic=${result.endBatteryTemperatureDeciC ?? -1} '
            'session=${result.sessionStart}->${result.sessionEnd}',
          );

          if (caseIndex + 1 < selectedCases.length) {
            await Future<void>.delayed(_betweenCases);
          }
        }

        final modelResult = LocalModelBenchmarkModelResult(
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          cases: List<LocalModelBenchmarkCaseResult>.unmodifiable(caseResults),
        );
        modelResults.add(modelResult);

        RuntimeEventLog.instance.emit(
          '[LOCAL_MODEL_BENCH_MODEL_END] '
          'model=${model.effectiveRuntimeModelId} '
          'quality=${modelResult.score}/${modelResult.maxScore} '
          'avg_first_content_ms=${modelResult.averageFirstContentMs.toStringAsFixed(0)} '
          'avg_total_ms=${modelResult.averageTotalMs.toStringAsFixed(0)} '
          'avg_prefill_ms=${modelResult.averagePrefillMs.toStringAsFixed(0)} '
          'avg_decode_tokens_s=${modelResult.averageDecodeTokensPerSecond.toStringAsFixed(2)} '
          'max_battery_temp_c=${modelResult.maxBatteryTemperatureC?.toStringAsFixed(1) ?? 'na'} '
          'battery_temp_delta_c=${modelResult.batteryTemperatureDeltaC?.toStringAsFixed(1) ?? 'na'} '
          'sdd_repeat_consistent=${modelResult.repeatedSddOutcomeConsistent?.toString() ?? 'na'}',
        );
      } on LocalModelBenchmarkCriticalResourceException {
        rethrow;
      } catch (error, stackTrace) {
        RuntimeEventLog.instance.emit(
          '[LOCAL_MODEL_BENCH_MODEL_FAILED] '
          'model=${model.effectiveRuntimeModelId} '
          'error=$error stack=$stackTrace',
        );

        if (!continueOnModelError) {
          rethrow;
        }

        failures.add(
          LocalModelBenchmarkFailure(
            modelId: model.effectiveRuntimeModelId,
            catalogModelId: model.id,
            displayName: model.displayName,
            error: error.toString(),
          ),
        );
      }
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_BENCH_END] models=${modelResults.length} '
      'failures=${failures.length} '
      'status=${failures.isEmpty ? 'success' : 'partial'}',
    );

    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    return LocalModelBenchmarkReport(
      createdAt: DateTime.now(),
      models: List<LocalModelBenchmarkModelResult>.unmodifiable(modelResults),
      failures: List<LocalModelBenchmarkFailure>.unmodifiable(failures),
    );
  }
  Future<LocalModelMemoryContextReport> runMemoryContextBenchmark({
    LocalModelBenchmarkProgress? onProgress,
    Iterable<String>? modelIds,
    bool continueOnModelError = true,
  }) async {
    final targets = await _resolveTargets(modelIds);
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider
        : null;
    final modelResults = <LocalModelMemoryContextModelResult>[];
    final failures = <LocalModelBenchmarkFailure>[];

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_MEMORY_CONTEXT_BEGIN] models=${targets.length} '
      'levels=${memoryContextTargetCharacters.join(',')}',
    );

    for (var modelIndex = 0; modelIndex < targets.length; modelIndex++) {
      final model = targets[modelIndex];
      try {
        if (androidRuntime != null) {
          await androidRuntime.resetBenchmarkNativeSessions();
          await Future<void>.delayed(_betweenCases);
        }

        final samples = <LocalModelMemoryContextSample>[];
        var stoppedEarly = false;
        String? stopReason;

        for (var levelIndex = 0;
            levelIndex < memoryContextTargetCharacters.length;
            levelIndex++) {
          final targetCharacters =
              memoryContextTargetCharacters[levelIndex];
          final benchmarkCase = memoryContextCaseFor(
            levelIndex: levelIndex,
            targetCharacters: targetCharacters,
          );
          onProgress?.call(
            '${model.displayName} context '
            '${levelIndex + 1}/${memoryContextTargetCharacters.length}',
          );

          try {
            final result = await _runCase(
              model: model,
              benchmarkCase: benchmarkCase,
            );
            samples.add(
              LocalModelMemoryContextSample(
                levelId: benchmarkCase.id,
                targetCharacters: targetCharacters,
                recovery: false,
                result: result,
              ),
            );

            RuntimeEventLog.instance.emit(
              '[LOCAL_MODEL_MEMORY_CONTEXT_LEVEL] '
              'model=${model.effectiveRuntimeModelId} '
              'level=${benchmarkCase.id} '
              'target_chars=$targetCharacters '
              'passed=${result.score == result.maxScore} '
              'n_ctx=${result.observedContext} '
              'pressure=${result.startPressure}->${result.endPressure} '
              'available=${result.startAvailableBytes ?? -1}->'
              '${result.endAvailableBytes ?? -1}',
            );

            if (result.endPressure == 'critical') {
              throw LocalModelBenchmarkCriticalResourceException(
                'Memory/context benchmark reached critical pressure.',
              );
            }
          } on LocalModelBenchmarkCriticalResourceException {
            rethrow;
          } catch (error) {
            stoppedEarly = true;
            stopReason =
                '${benchmarkCase.id}: ${error.toString()}';
            break;
          }

          await Future<void>.delayed(_betweenCases);
        }

        onProgress?.call('${model.displayName} recovery');
        try {
          final recovery = await _runCase(
            model: model,
            benchmarkCase: memoryContextRecoveryCase,
          );
          samples.add(
            LocalModelMemoryContextSample(
              levelId: memoryContextRecoveryCase.id,
              targetCharacters: 0,
              recovery: true,
              result: recovery,
            ),
          );
          if (recovery.endPressure == 'critical') {
            throw LocalModelBenchmarkCriticalResourceException(
              'Memory/context recovery reached critical pressure.',
            );
          }
        } on LocalModelBenchmarkCriticalResourceException {
          rethrow;
        } catch (error) {
          stoppedEarly = true;
          stopReason = stopReason == null
              ? 'recovery: ${error.toString()}'
              : '$stopReason; recovery: ${error.toString()}';
        }

        final result = LocalModelMemoryContextModelResult(
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          samples: List<LocalModelMemoryContextSample>.unmodifiable(samples),
          stoppedEarly: stoppedEarly,
          stopReason: stopReason,
        );
        modelResults.add(result);

        RuntimeEventLog.instance.emit(
          '[LOCAL_MODEL_MEMORY_CONTEXT_MODEL_END] '
          'model=${model.effectiveRuntimeModelId} '
          'passed=${result.passedContextLevels}/'
          '${memoryContextTargetCharacters.length} '
          'recovery=${result.recoveryPassed} '
          'max_ctx=${result.maxObservedContext} '
          'pressure=${result.worstPressure} '
          'stopped_early=${result.stoppedEarly}',
        );
      } on LocalModelBenchmarkCriticalResourceException {
        rethrow;
      } catch (error, stackTrace) {
        RuntimeEventLog.instance.emit(
          '[LOCAL_MODEL_MEMORY_CONTEXT_FAILED] '
          'model=${model.effectiveRuntimeModelId} '
          'error=$error stack=$stackTrace',
        );
        if (!continueOnModelError) rethrow;
        failures.add(
          LocalModelBenchmarkFailure(
            modelId: model.effectiveRuntimeModelId,
            catalogModelId: model.id,
            displayName: model.displayName,
            error: error.toString(),
          ),
        );
      }
    }

    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    return LocalModelMemoryContextReport(
      createdAt: DateTime.now(),
      models:
          List<LocalModelMemoryContextModelResult>.unmodifiable(modelResults),
      failures: List<LocalModelBenchmarkFailure>.unmodifiable(failures),
    );
  }

  Future<LocalModelPerformanceReport> runPerformanceBenchmark({
    LocalModelBenchmarkProgress? onProgress,
    Iterable<String>? modelIds,
    bool continueOnModelError = true,
  }) async {
    final targets = await _resolveTargets(modelIds);
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider
        : null;
    final modelResults = <LocalModelPerformanceModelResult>[];
    final failures = <LocalModelBenchmarkFailure>[];

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_PERF_BEGIN] models=${targets.length} '
      'warm_repetitions=$performanceWarmRepetitions',
    );

    try {
      for (var modelIndex = 0; modelIndex < targets.length; modelIndex++) {
        final model = targets[modelIndex];

        try {
          if (androidRuntime != null) {
            await androidRuntime.resetBenchmarkNativeSessions();
            await Future<void>.delayed(_betweenCases);
          }

          final samples = <LocalModelPerformanceSample>[];

          onProgress?.call(
            '${model.displayName} cold '
            '${modelIndex + 1}/${targets.length}',
          );
          final cold = await _runCase(
            model: model,
            benchmarkCase: performanceCase,
          );
          samples.add(
            LocalModelPerformanceSample(
              phase: LocalModelPerformancePhase.cold,
              repetition: 1,
              result: cold,
            ),
          );

          for (var repetition = 1;
              repetition <= performanceWarmRepetitions;
              repetition++) {
            await Future<void>.delayed(_betweenCases);
            onProgress?.call(
              '${model.displayName} warm '
              '$repetition/$performanceWarmRepetitions',
            );
            final warm = await _runCase(
              model: model,
              benchmarkCase: performanceCase,
            );
            samples.add(
              LocalModelPerformanceSample(
                phase: LocalModelPerformancePhase.warm,
                repetition: repetition,
                result: warm,
              ),
            );
          }

          final modelResult = LocalModelPerformanceModelResult(
            modelId: model.effectiveRuntimeModelId,
            catalogModelId: model.id,
            displayName: model.displayName,
            samples: List<LocalModelPerformanceSample>.unmodifiable(samples),
          );
          modelResults.add(modelResult);

          RuntimeEventLog.instance.emit(
            '[LOCAL_MODEL_PERF_MODEL_END] '
            'model=${model.effectiveRuntimeModelId} '
            'cold_first_ms=${cold.firstContentMs} '
            'cold_prefill_ms=${cold.prefillMs} '
            'warm_first_ms='
            '${modelResult.averageWarmFirstContentMs.toStringAsFixed(0)} '
            'warm_prefill_ms='
            '${modelResult.averageWarmPrefillMs.toStringAsFixed(0)} '
            'warm_decode_tokens_s='
            '${modelResult.averageWarmDecodeTokensPerSecond.toStringAsFixed(2)} '
            'cold_confirmed=${modelResult.coldSessionConfirmed} '
            'warm_confirmed=${modelResult.warmSessionConfirmed}',
          );
        } on LocalModelBenchmarkCriticalResourceException {
          rethrow;
        } catch (error, stackTrace) {
          RuntimeEventLog.instance.emit(
            '[LOCAL_MODEL_PERF_MODEL_FAILED] '
            'model=${model.effectiveRuntimeModelId} '
            'error=$error stack=$stackTrace',
          );
          if (!continueOnModelError) rethrow;
          failures.add(
            LocalModelBenchmarkFailure(
              modelId: model.effectiveRuntimeModelId,
              catalogModelId: model.id,
              displayName: model.displayName,
              error: error.toString(),
            ),
          );
        }
      }
    } finally {
      if (androidRuntime != null) {
        await androidRuntime.resetBenchmarkNativeSessions();
      }
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_PERF_END] models=${modelResults.length} '
      'failures=${failures.length} '
      'status=${failures.isEmpty ? 'success' : 'partial'}',
    );

    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    return LocalModelPerformanceReport(
      createdAt: DateTime.now(),
      models:
          List<LocalModelPerformanceModelResult>.unmodifiable(modelResults),
      failures: List<LocalModelBenchmarkFailure>.unmodifiable(failures),
    );
  }

  Future<LocalModelThermalReport> runThermalStressBenchmark({
    required String modelId,
    LocalModelBenchmarkProgress? onProgress,
  }) async {
    final targets = await _resolveTargets(<String>[modelId]);
    if (targets.length != 1) {
      throw StateError('Thermal stress requires exactly one model.');
    }

    final model = targets.single;
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider
        : null;
    final failures = <LocalModelBenchmarkFailure>[];
    final modelResults = <LocalModelThermalModelResult>[];

    final baseline = await _resourceMonitor.sample();
    if (baseline?.critical == true) {
      throw const LocalModelBenchmarkCriticalResourceException(
        'Thermal stress not started: critical memory pressure.',
      );
    }

    final baselineTemp = baseline?.batteryTemperatureDeciC;
    if (baselineTemp != null &&
        baselineTemp >= thermalStartMaxBatteryTemperatureDeciC) {
      throw LocalModelBenchmarkCriticalResourceException(
        'Thermal stress not started: battery proxy already '
        '${(baselineTemp / 10).toStringAsFixed(1)}°C.',
      );
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_THERMAL_BEGIN] '
      'model=${model.effectiveRuntimeModelId} '
      'repetitions=$thermalStressRepetitions '
      'baseline_battery_temp_decic=${baselineTemp ?? -1}',
    );

    try {
      if (androidRuntime != null) {
        await androidRuntime.resetBenchmarkNativeSessions();
        await Future<void>.delayed(_betweenCases);
      }

      onProgress?.call('${model.displayName} warm-up');
      await _runCase(
        model: model,
        benchmarkCase: performanceCase,
      );

      final samples = <LocalModelThermalSample>[];
      var stoppedEarly = false;
      String? stopReason;

      for (var repetition = 1;
          repetition <= thermalStressRepetitions;
          repetition++) {
        final before = await _resourceMonitor.sample();
        if (before?.critical == true) {
          stoppedEarly = true;
          stopReason = 'critical_memory';
          break;
        }

        final beforeTemp = before?.batteryTemperatureDeciC;
        if (beforeTemp != null &&
            beforeTemp >= thermalStopBatteryTemperatureDeciC) {
          stoppedEarly = true;
          stopReason = 'temperature_cutoff';
          break;
        }
        if (baselineTemp != null &&
            beforeTemp != null &&
            beforeTemp - baselineTemp >= thermalMaxRiseDeciC) {
          stoppedEarly = true;
          stopReason = 'temperature_rise_cutoff';
          break;
        }

        onProgress?.call(
          '${model.displayName} stress '
          '$repetition/$thermalStressRepetitions',
        );

        final result = await _runCase(
          model: model,
          benchmarkCase: performanceCase,
        );
        samples.add(
          LocalModelThermalSample(
            repetition: repetition,
            result: result,
          ),
        );

        final endTemp = result.endBatteryTemperatureDeciC;
        if (result.endPressure == 'critical') {
          stoppedEarly = true;
          stopReason = 'critical_memory';
          break;
        }
        if (endTemp != null &&
            endTemp >= thermalStopBatteryTemperatureDeciC) {
          stoppedEarly = true;
          stopReason = 'temperature_cutoff';
          break;
        }
        if (baselineTemp != null &&
            endTemp != null &&
            endTemp - baselineTemp >= thermalMaxRiseDeciC) {
          stoppedEarly = true;
          stopReason = 'temperature_rise_cutoff';
          break;
        }

        if (repetition < thermalStressRepetitions) {
          await Future<void>.delayed(thermalBetweenCases);
        }
      }

      if (samples.isEmpty) {
        throw StateError(
          'Thermal stress produced no measurable stress samples.',
        );
      }

      final result = LocalModelThermalModelResult(
        modelId: model.effectiveRuntimeModelId,
        catalogModelId: model.id,
        displayName: model.displayName,
        baselineBatteryTemperatureDeciC: baselineTemp,
        samples: List<LocalModelThermalSample>.unmodifiable(samples),
        stoppedEarly: stoppedEarly,
        stopReason: stopReason,
      );
      modelResults.add(result);

      RuntimeEventLog.instance.emit(
        '[LOCAL_MODEL_THERMAL_END] '
        'model=${model.effectiveRuntimeModelId} '
        'samples=${samples.length} '
        'rise_c=${result.batteryTemperatureRiseC?.toStringAsFixed(1) ?? 'na'} '
        'decode_retention=${result.decodeRetention.toStringAsFixed(2)} '
        'first_slowdown='
        '${result.firstContentSlowdown.isFinite ? result.firstContentSlowdown.toStringAsFixed(2) : 'na'} '
        'stopped_early=$stoppedEarly '
        'reason=${stopReason ?? 'none'}',
      );
    } on LocalModelBenchmarkCriticalResourceException {
      rethrow;
    } catch (error, stackTrace) {
      RuntimeEventLog.instance.emit(
        '[LOCAL_MODEL_THERMAL_FAILED] '
        'model=${model.effectiveRuntimeModelId} '
        'error=$error stack=$stackTrace',
      );
      failures.add(
        LocalModelBenchmarkFailure(
          modelId: model.effectiveRuntimeModelId,
          catalogModelId: model.id,
          displayName: model.displayName,
          error: error.toString(),
        ),
      );
    } finally {
      if (androidRuntime != null) {
        await androidRuntime.resetBenchmarkNativeSessions();
      }
    }

    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    return LocalModelThermalReport(
      createdAt: DateTime.now(),
      models: List<LocalModelThermalModelResult>.unmodifiable(modelResults),
      failures: List<LocalModelBenchmarkFailure>.unmodifiable(failures),
    );
  }

  Future<VulkanLayerSweepReport> runVulkanLayerSweep({
    LocalModelBenchmarkProgress? onProgress,
    Iterable<String>? modelIds,
  }) async {
    final runtime = _runtimeProvider;
    if (runtime is! AndroidFfiRuntimeProvider) {
      throw StateError(
        'The 0/10/99 GPU-layer sweep requires the Android FFI runtime.',
      );
    }

    final targets = await _resolveTargets(modelIds);
    final benchmarkCase =
        cases.firstWhere((item) => item.id == 'vulkan_fact');
    final samples = <VulkanLayerSweepSample>[];

    RuntimeEventLog.instance.emit(
      '[LOCAL_VULKAN_SWEEP_BEGIN] profiles=0,10,99 '
      'models=${targets.length} repetitions=$vulkanSweepRepetitions',
    );

    try {
      for (var repetition = 1;
          repetition <= vulkanSweepRepetitions;
          repetition++) {
        // Counterbalance both profile and model order so the hottest part of
        // the run is not always assigned to the same candidate.
        final profileOrder = repetition.isOdd
            ? vulkanSweepProfiles
            : vulkanSweepProfiles.reversed.toList(growable: false);
        final modelOrder = repetition.isOdd
            ? targets
            : targets.reversed.toList(growable: false);

        for (final requestedLayers in profileOrder) {
          await runtime.setBenchmarkGpuLayersOverride(requestedLayers);

          for (final model in modelOrder) {
            onProgress?.call(
              'Vulkan $requestedLayers • ${model.displayName} '
              '$repetition/$vulkanSweepRepetitions',
            );

            final result = await _runCase(
              model: model,
              benchmarkCase: benchmarkCase,
            );
            samples.add(
              VulkanLayerSweepSample(
                requestedGpuLayers: requestedLayers,
                modelId: model.effectiveRuntimeModelId,
                displayName: model.displayName,
                repetition: repetition,
                result: result,
              ),
            );

            RuntimeEventLog.instance.emit(
              '[LOCAL_VULKAN_SWEEP_CASE] '
              'model=${model.effectiveRuntimeModelId} '
              'requested_gpu_layers=$requestedLayers '
              'observed_gpu_layers=${result.observedGpuLayers} '
              'repetition=$repetition '
              'first_content_ms=${result.firstContentMs} '
              'prefill_ms=${result.prefillMs} '
              'total_ms=${result.totalMs} '
              'reported_tokens=${result.reportedTokens} '
              'decode_tokens_s=${result.decodeTokensPerSecond.toStringAsFixed(2)} '
              'pressure=${result.startPressure}->${result.endPressure} '
              'start_available_bytes=${result.startAvailableBytes ?? -1} '
              'end_available_bytes=${result.endAvailableBytes ?? -1} '
              'start_battery_temp_decic=${result.startBatteryTemperatureDeciC ?? -1} '
              'end_battery_temp_decic=${result.endBatteryTemperatureDeciC ?? -1}',
            );

            await Future<void>.delayed(_betweenCases);
          }
        }
      }
    } finally {
      await runtime.setBenchmarkGpuLayersOverride(null);
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_VULKAN_SWEEP_END] samples=${samples.length} status=success',
    );

    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    return VulkanLayerSweepReport(
      createdAt: DateTime.now(),
      samples: List<VulkanLayerSweepSample>.unmodifiable(samples),
    );
  }

  Future<List<AiModel>> _resolveTargets(
    Iterable<String>? requestedModelIds,
  ) async {
    final available = await loadBenchmarkCandidates();
    final requested = (requestedModelIds ?? defaultOrchestratorTargetModelIds)
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    if (requested.isEmpty) {
      throw StateError('Select at least one downloaded model.');
    }

    final targets = <AiModel>[];
    final missing = <String>[];
    final selectedIds = <String>{};

    for (final requestedId in requested) {
      AiModel? found;

      // Prefer the exact catalogue/import id so imported variants that share
      // a runtime family remain individually benchmarkable.
      for (final candidate in available) {
        if (candidate.id == requestedId) {
          found = candidate;
          break;
        }
      }

      if (found == null) {
        for (final candidate in available) {
          if (candidate.effectiveRuntimeModelId == requestedId) {
            found = candidate;
            break;
          }
        }
      }

      if (found == null || !isRunnableCandidate(found)) {
        missing.add(requestedId);
        continue;
      }

      if (selectedIds.add(found.id)) {
        targets.add(found);
      }
    }

    if (missing.isNotEmpty) {
      throw StateError(
        'Selected benchmark model(s) are unavailable or not validated: '
        '${missing.join(', ')}',
      );
    }

    return targets;
  }
  Future<LocalModelBenchmarkCaseResult> _runCase({
    required AiModel model,
    required LocalModelBenchmarkCase benchmarkCase,
  }) async {
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider
        : null;
    final modelPath = model.localPath;
    final hadSessionBefore = androidRuntime != null &&
        modelPath != null &&
        androidRuntime.hasActiveNativeSessionForModelPath(modelPath);

    final startSample = await _resourceMonitor.sample();
    if (startSample?.critical == true) {
      throw LocalModelBenchmarkCriticalResourceException(
        'Benchmark stopped before ${benchmarkCase.id}: critical memory.',
      );
    }

    final cancellationToken = CancellationToken();
    final stopwatch = Stopwatch()..start();
    final streamedText = StringBuffer();

    String? finalText;
    var reportedTokens = 0;
    var firstContentMs = -1;
    var observedPrefillMs = -1;
    var observedGpuLayers = 0;
    var observedBatch = 0;
    var observedMicroBatch = 0;
    var observedContext = 0;

    final sessionId =
        'debug-bench-${model.effectiveRuntimeModelId}-${benchmarkCase.id}-'
        '${DateTime.now().microsecondsSinceEpoch}';

    await for (final chunk in _runtimeProvider.streamInference(
      request: InferenceRequest(
        sessionId: sessionId,
        prompt: benchmarkCase.prompt,
        context: benchmarkCase.context,
        modelId: model.effectiveRuntimeModelId,
        modelPath: model.localPath,
        maxTokens: _maxTokens,
        temperature: _temperature,
        topP: 0.9,
        repeatPenalty: 1.1,
        isOffline: true,
      ),
      cancellationToken: cancellationToken,
    )) {
      final native = androidRuntime != null && modelPath != null
          ? androidRuntime.nativeSessionMetricsForModelPath(modelPath) ??
              _resourceMonitor.native
          : _resourceMonitor.native;
      final prefillMs = native['prefill_ms'] ?? -1;
      final gpuLayers = native['gpu_layers'] ?? 0;
      final batch = native['batch'] ?? 0;
      final microBatch = native['micro_batch'] ?? 0;
      final context = native['context'] ?? 0;
      if (prefillMs >= 0) {
        observedPrefillMs = prefillMs;
      }
      if (gpuLayers > observedGpuLayers) {
        observedGpuLayers = gpuLayers;
      }
      if (batch > observedBatch) {
        observedBatch = batch;
      }
      if (microBatch > observedMicroBatch) {
        observedMicroBatch = microBatch;
      }
      if (context > observedContext) {
        observedContext = context;
      }

      if (chunk.runtimeNotice != null) {
        continue;
      }
      if (chunk.isError) {
        throw StateError(
          chunk.errorMessage ?? 'Benchmark inference failed.',
        );
      }

      if (!chunk.isFinal && chunk.text.isNotEmpty) {
        if (firstContentMs < 0) {
          firstContentMs = stopwatch.elapsedMilliseconds;
        }
        streamedText.write(chunk.text);
      }

      if (chunk.isFinal) {
        if (chunk.text.trim().isNotEmpty) {
          finalText = chunk.text.trim();
        }
        reportedTokens = chunk.tokensGenerated;
      }
    }

    stopwatch.stop();

    final response =
        (finalText?.trim().isNotEmpty ?? false)
            ? finalText!.trim()
            : streamedText.toString().trim();

    if (response.isEmpty) {
      throw StateError(
        'Benchmark ${benchmarkCase.id} returned an empty response.',
      );
    }

    if (firstContentMs < 0) {
      firstContentMs = stopwatch.elapsedMilliseconds;
    }

    final endSample = await _resourceMonitor.sample();
    final hasSessionAfter = androidRuntime != null &&
        modelPath != null &&
        androidRuntime.hasActiveNativeSessionForModelPath(modelPath);
    final sessionStart = androidRuntime == null
        ? 'unknown'
        : hadSessionBefore
            ? 'warm'
            : 'cold';
    final sessionEnd = androidRuntime == null
        ? 'unknown'
        : hasSessionAfter
            ? 'kept'
            : 'released';

    return LocalModelBenchmarkCaseResult(
      caseId: benchmarkCase.id,
      response: response,
      score: benchmarkCase.score(response),
      maxScore: benchmarkCase.maxScore,
      forbiddenHits: benchmarkCase.forbiddenHits(response),
      firstContentMs: firstContentMs,
      totalMs: stopwatch.elapsedMilliseconds,
      reportedTokens: reportedTokens,
      prefillMs: observedPrefillMs,
      observedGpuLayers: observedGpuLayers,
      observedBatch: observedBatch,
      observedMicroBatch: observedMicroBatch,
      observedContext: observedContext,
      startPressure: startSample?.pressure ?? 'unknown',
      endPressure: endSample?.pressure ?? 'unknown',
      startAvailableBytes: startSample?.availableBytes,
      endAvailableBytes: endSample?.availableBytes,
      startBatteryTemperatureDeciC: startSample?.batteryTemperatureDeciC,
      endBatteryTemperatureDeciC: endSample?.batteryTemperatureDeciC,
      sessionStart: sessionStart,
      sessionEnd: sessionEnd,
    );
  }
}
