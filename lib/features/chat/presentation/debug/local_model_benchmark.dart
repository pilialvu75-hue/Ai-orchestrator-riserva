import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/diagnostics/github_diagnostics.dart';
import 'package:ai_orchestrator/core/runtime/inference/android_ffi_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
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
  });

  final String id;
  final String prompt;
  final List<ChatTurn> context;
  final List<List<String>> requiredAnyGroups;
  final List<String> forbiddenPhrases;

  int get maxScore => requiredAnyGroups.length;

  int score(String response) {
    final normalized = response.trim().toLowerCase();
    var score = 0;

    for (final group in requiredAnyGroups) {
      if (group.any((candidate) => normalized.contains(candidate.toLowerCase()))) {
        score++;
      }
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
    required this.prefillMs,
    required this.totalMs,
    required this.reportedTokens,
    required this.observedGpuLayers,
    required this.observedBatch,
    required this.observedMicroBatch,
    required this.startPressure,
    required this.endPressure,
    required this.startAvailableBytes,
    required this.endAvailableBytes,
    required this.startBatteryTemperatureMilliC,
    required this.endBatteryTemperatureMilliC,
    required this.sessionStart,
    required this.sessionEnd,
  });

  final String caseId;
  final String response;
  final int score;
  final int maxScore;
  final int forbiddenHits;
  final int firstContentMs;
  final int prefillMs;
  final int totalMs;
  final int reportedTokens;
  final int observedGpuLayers;
  final int observedBatch;
  final int observedMicroBatch;
  final String startPressure;
  final String endPressure;
  final int? startAvailableBytes;
  final int? endAvailableBytes;
  final int? startBatteryTemperatureMilliC;
  final int? endBatteryTemperatureMilliC;
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
    required this.requestedGpuLayers,
    required this.cases,
  });

  final String modelId;
  final String displayName;
  final int requestedGpuLayers;
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
    if (valid.isEmpty) return -1;
    return valid.reduce((a, b) => a + b) / valid.length;
  }

  double? get averageBatteryTemperatureDeltaC {
    final deltas = <double>[];
    for (final item in cases) {
      final start = item.startBatteryTemperatureMilliC;
      final end = item.endBatteryTemperatureMilliC;
      if (start != null && end != null) {
        deltas.add((end - start) / 1000);
      }
    }
    if (deltas.isEmpty) return null;
    return deltas.reduce((a, b) => a + b) / deltas.length;
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

class LocalModelBenchmarkReport {
  const LocalModelBenchmarkReport({
    required this.createdAt,
    required this.models,
  });

  final DateTime createdAt;
  final List<LocalModelBenchmarkModelResult> models;

  String toPlainText({bool includeResponses = true}) {
    final buffer = StringBuffer()
      ..writeln('LOCAL MODEL BENCHMARK')
      ..writeln('created_at=${createdAt.toIso8601String()}')
      ..writeln(
        'order=${models.map((item) => '${item.modelId}@gpu${item.requestedGpuLayers}').join(' -> ')}',
      )
      ..writeln();

    for (final model in models) {
      buffer
        ..writeln(
          '${model.displayName} [${model.modelId}] gpu_request=${model.requestedGpuLayers}',
        )
        ..writeln('quality=${model.score}/${model.maxScore}')
        ..writeln(
          'avg_first_content_ms=${model.averageFirstContentMs.toStringAsFixed(0)}',
        )
        ..writeln('avg_prefill_ms=${model.averagePrefillMs.toStringAsFixed(0)}')
        ..writeln('avg_total_ms=${model.averageTotalMs.toStringAsFixed(0)}')
        ..writeln(
          'avg_decode_tokens_s=${model.averageDecodeTokensPerSecond.toStringAsFixed(2)}',
        )
        ..writeln(
          'avg_battery_temp_delta_c='
          '${model.averageBatteryTemperatureDeltaC?.toStringAsFixed(2) ?? 'n/a'}',
        )
        ..writeln(
          'sdd_repeat_consistent=${model.repeatedSddOutcomeConsistent ?? 'n/a'}',
        );

      for (final item in model.cases) {
        buffer.writeln(
          '- ${item.caseId}: score=${item.score}/${item.maxScore} '
          'forbidden=${item.forbiddenHits} '
          'first=${item.firstContentMs}ms prefill=${item.prefillMs}ms '
          'total=${item.totalMs}ms tokens=${item.reportedTokens} '
          'decode=${item.decodeTokensPerSecond.toStringAsFixed(2)}tok/s '
          'gpu=${item.observedGpuLayers} '
          'batch=${item.observedBatch}/${item.observedMicroBatch} '
          'pressure=${item.startPressure}->${item.endPressure} '
          'battery_temp_c='
          '${item.startBatteryTemperatureMilliC == null ? 'n/a' : (item.startBatteryTemperatureMilliC! / 1000).toStringAsFixed(1)}'
          '->'
          '${item.endBatteryTemperatureMilliC == null ? 'n/a' : (item.endBatteryTemperatureMilliC! / 1000).toStringAsFixed(1)} '
          'session=${item.sessionStart}->${item.sessionEnd}',
        );
        if (includeResponses) {
          buffer.writeln('  response=${item.response.replaceAll('\n', ' ')}');
        }
      }
      buffer.writeln();
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

  static const List<int> vulkanMatrixGpuLayers = <int>[0, 10, 50];
  static const Set<String> _vulkanMatrixCaseIds = <String>{
    'vulkan_fact',
    'arithmetic',
    'ssd_hdd_followup',
  };

  static const List<String> _targetModelIds = <String>[
    LocalInferenceModelIds.phi35Mini,
    LocalInferenceModelIds.nemotron3Nano4b,
  ];

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

  final LocalRuntimeProvider _runtimeProvider;
  final LocalAiRepository _localAiRepository;
  final ResourceMonitor _resourceMonitor;

  Future<LocalModelBenchmarkReport> run({
    LocalModelBenchmarkProgress? onProgress,
    int? gpuLayersOverride,
    List<LocalModelBenchmarkCase>? benchmarkCases,
  }) async {
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider as AndroidFfiRuntimeProvider
        : null;
    if (gpuLayersOverride != null && androidRuntime == null) {
      throw StateError(
        'GPU-layer benchmark override requires AndroidFfiRuntimeProvider.',
      );
    }
    if (gpuLayersOverride != null) {
      await androidRuntime!.setBenchmarkGpuLayersOverride(gpuLayersOverride);
    }

    final activeCases = benchmarkCases ?? cases;
    final availableResult = await _localAiRepository.getAvailableModels();
    final available = availableResult.fold<List<AiModel>>(
      (failure) => throw StateError(
        'Model catalogue lookup failed: ${failure.message}',
      ),
      (models) => models,
    );

    final targets = <AiModel>[];
    final missing = <String>[];

    for (final modelId in _targetModelIds) {
      AiModel? found;
      for (final candidate in available) {
        if (candidate.effectiveRuntimeModelId == modelId ||
            candidate.id == modelId) {
          found = candidate;
          break;
        }
      }

      if (found == null ||
          !found.isDownloaded ||
          (found.localPath?.trim().isEmpty ?? true)) {
        missing.add(modelId);
      } else {
        targets.add(found);
      }
    }

    if (missing.isNotEmpty) {
      throw StateError(
        'Benchmark requires both downloaded models. Missing: ${missing.join(', ')}',
      );
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_BENCH_BEGIN] models=${targets.map((m) => m.effectiveRuntimeModelId).join(',')} '
      'cases=${activeCases.length} max_tokens=$_maxTokens temperature=$_temperature '
      'requested_gpu_layers=${androidRuntime?.requestedGpuLayers ?? -1}',
    );

    final modelResults = <LocalModelBenchmarkModelResult>[];

    for (var modelIndex = 0; modelIndex < targets.length; modelIndex++) {
      final model = targets[modelIndex];
      final caseResults = <LocalModelBenchmarkCaseResult>[];

      RuntimeEventLog.instance.emit(
        '[LOCAL_MODEL_BENCH_MODEL_BEGIN] model=${model.effectiveRuntimeModelId} '
        'order=${modelIndex + 1}/${targets.length}',
      );

      for (var caseIndex = 0; caseIndex < activeCases.length; caseIndex++) {
        final benchmarkCase = activeCases[caseIndex];
        onProgress?.call(
          '${model.displayName} ${caseIndex + 1}/${activeCases.length}',
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
          'prefill_ms=${result.prefillMs} '
          'total_ms=${result.totalMs} '
          'reported_tokens=${result.reportedTokens} '
          'decode_tokens_s=${result.decodeTokensPerSecond.toStringAsFixed(2)} '
          'gpu_layers=${result.observedGpuLayers} '
          'n_batch=${result.observedBatch} '
          'n_ubatch=${result.observedMicroBatch} '
          'pressure=${result.startPressure}->${result.endPressure} '
          'start_available_bytes=${result.startAvailableBytes ?? -1} '
          'end_available_bytes=${result.endAvailableBytes ?? -1} '
          'start_battery_temp_milli_c=${result.startBatteryTemperatureMilliC ?? -1} '
          'end_battery_temp_milli_c=${result.endBatteryTemperatureMilliC ?? -1} '
          'session=${result.sessionStart}->${result.sessionEnd}',
        );

        if (caseIndex + 1 < activeCases.length) {
          await Future<void>.delayed(_betweenCases);
        }
      }

      final modelResult = LocalModelBenchmarkModelResult(
        modelId: model.effectiveRuntimeModelId,
        displayName: model.displayName,
        requestedGpuLayers: androidRuntime?.requestedGpuLayers ?? -1,
        cases: List<LocalModelBenchmarkCaseResult>.unmodifiable(caseResults),
      );
      modelResults.add(modelResult);

      RuntimeEventLog.instance.emit(
        '[LOCAL_MODEL_BENCH_MODEL_END] '
        'model=${model.effectiveRuntimeModelId} '
        'quality=${modelResult.score}/${modelResult.maxScore} '
        'requested_gpu_layers=${modelResult.requestedGpuLayers} '
        'avg_first_content_ms=${modelResult.averageFirstContentMs.toStringAsFixed(0)} '
        'avg_prefill_ms=${modelResult.averagePrefillMs.toStringAsFixed(0)} '
        'avg_total_ms=${modelResult.averageTotalMs.toStringAsFixed(0)} '
        'avg_decode_tokens_s=${modelResult.averageDecodeTokensPerSecond.toStringAsFixed(2)} '
        'sdd_repeat_consistent=${modelResult.repeatedSddOutcomeConsistent?.toString() ?? 'na'}',
      );
    }

    RuntimeEventLog.instance.emit(
      '[LOCAL_MODEL_BENCH_END] models=${modelResults.length} status=success',
    );

    // Benchmark results are already emitted as privacy-safe metric events.
    // If public Diagnostics is enabled, flush them immediately instead of
    // waiting for the periodic one-minute uploader.
    final diagnostics = GitHubDiagnostics.instance;
    await diagnostics.initialize();
    if (diagnostics.enabled) {
      // RuntimeEventLog uses an asynchronous broadcast stream. Yield once so
      // the final benchmark events reach the Diagnostics collector before it
      // seals and uploads the batch.
      await Future<void>.delayed(Duration.zero);
      await diagnostics.sync();
    }

    final report = LocalModelBenchmarkReport(
      createdAt: DateTime.now(),
      models: List<LocalModelBenchmarkModelResult>.unmodifiable(modelResults),
    );
    if (gpuLayersOverride != null) {
      await androidRuntime!.setBenchmarkGpuLayersOverride(null);
    }
    return report;
  }

  Future<LocalModelBenchmarkReport> runVulkanMatrix({
    LocalModelBenchmarkProgress? onProgress,
  }) async {
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider as AndroidFfiRuntimeProvider
        : null;
    if (androidRuntime == null) {
      throw StateError('Vulkan matrix requires the Android FFI runtime.');
    }

    final matrixCases = cases
        .where((item) => _vulkanMatrixCaseIds.contains(item.id))
        .toList(growable: false);
    final combined = <LocalModelBenchmarkModelResult>[];
    try {
      for (final layers in vulkanMatrixGpuLayers) {
        final report = await run(
          gpuLayersOverride: layers,
          benchmarkCases: matrixCases,
          onProgress: (message) =>
              onProgress?.call('GPU $layers • $message'),
        );
        combined.addAll(report.models);
      }
    } finally {
      await androidRuntime.setBenchmarkGpuLayersOverride(null);
    }

    return LocalModelBenchmarkReport(
      createdAt: DateTime.now(),
      models: List<LocalModelBenchmarkModelResult>.unmodifiable(combined),
    );
  }

  Future<LocalModelBenchmarkCaseResult> _runCase({
    required AiModel model,
    required LocalModelBenchmarkCase benchmarkCase,
  }) async {
    final androidRuntime = _runtimeProvider is AndroidFfiRuntimeProvider
        ? _runtimeProvider as AndroidFfiRuntimeProvider
        : null;
    final modelPath = model.localPath;
    final hadSessionBefore = androidRuntime != null &&
        modelPath != null &&
        androidRuntime.hasActiveNativeSessionForModelPath(modelPath);

    final startSample = await _resourceMonitor.sample();
    if (startSample?.critical == true) {
      throw StateError(
        'Benchmark stopped before ${benchmarkCase.id}: critical memory.',
      );
    }

    final cancellationToken = CancellationToken();
    final stopwatch = Stopwatch()..start();
    final streamedText = StringBuffer();

    String? finalText;
    var reportedTokens = 0;
    var firstContentMs = -1;
    var observedGpuLayers = 0;
    var observedBatch = 0;
    var observedMicroBatch = 0;
    var prefillMs = -1;

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
      final native = _resourceMonitor.native;
      final gpuLayers = native['gpu_layers'] ?? 0;
      final batch = native['batch'] ?? 0;
      final microBatch = native['micro_batch'] ?? 0;
      final nativePrefillMs = native['prefill_ms'] ?? -1;
      if (nativePrefillMs >= 0) {
        prefillMs = nativePrefillMs;
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
      prefillMs: prefillMs,
      totalMs: stopwatch.elapsedMilliseconds,
      reportedTokens: reportedTokens,
      observedGpuLayers: observedGpuLayers,
      observedBatch: observedBatch,
      observedMicroBatch: observedMicroBatch,
      startPressure: startSample?.pressure ?? 'unknown',
      endPressure: endSample?.pressure ?? 'unknown',
      startAvailableBytes: startSample?.availableBytes,
      endAvailableBytes: endSample?.availableBytes,
      startBatteryTemperatureMilliC:
          startSample?.batteryTemperatureMilliC,
      endBatteryTemperatureMilliC:
          endSample?.batteryTemperatureMilliC,
      sessionStart: sessionStart,
      sessionEnd: sessionEnd,
    );
  }
}
