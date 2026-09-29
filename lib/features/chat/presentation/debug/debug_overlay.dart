import 'dart:async';
import 'dart:io';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_benchmark_score_store.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/local_model_benchmark.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum DebugLabRunStatus {
  idle,
  running,
  success,
  failed,
  timeout,
}

class DebugOverlay extends StatefulWidget {
  const DebugOverlay({
    super.key,
    required this.onSendThroughChatPipeline,
    required this.onRenderVoiceInference,
    required this.onClearChat,
    required this.assistantTextSize,
    required this.onAssistantTextSizeChanged,
  });

  final void Function(
    String text,
    List<ChatAttachment> attachments,
  ) onSendThroughChatPipeline;

  final void Function({
    required String prompt,
    required String response,
  }) onRenderVoiceInference;

  final VoidCallback onClearChat;

  final AssistantMessageTextSize assistantTextSize;

  final ValueChanged<AssistantMessageTextSize>
      onAssistantTextSizeChanged;

  @override
  State<DebugOverlay> createState() =>
      _DebugOverlayState();
}

class _DebugOverlayState
    extends State<DebugOverlay> {
  static const String _assetImagePath =
      'assets/debug_lab/test_image.png';

  static const Duration _voiceTimeout =
      Duration(seconds: 120);

  static const Duration _chatTimeout =
      Duration(seconds: 10);

  static const Duration _visionTimeout =
      Duration(seconds: 20);

  static const Duration _benchmarkTimeout =
      Duration(minutes: 12);

  static const Duration _vulkanSweepTimeout =
      Duration(minutes: 20);

  /// Numero massimo di righe copiate dal log persistente.
  ///
  /// Il file su disco serve per sopravvivere ai crash nativi e può
  /// contenere più sessioni. Per la diagnostica dal telefono ci
  /// interessano soprattutto gli eventi immediatamente precedenti
  /// al crash.
  static const int _persistedLogCopyLines = 200;

  late final LocalRuntimeProvider
      _runtimeProvider;

  late final LocalAiRepository
      _localAiRepository;

  late final LocalModelBenchmarkRunner
      _localModelBenchmark;

  late final LocalBenchmarkScoreStore
      _benchmarkScoreStore;

  DebugLabRunStatus _status =
      DebugLabRunStatus.idle;

  String _statusMessage = 'Ready';

  String _activeTest = 'None';

  bool _running = false;

  @override
  void initState() {
    super.initState();

    _runtimeProvider =
        di.sl<LocalRuntimeProvider>();

    _localAiRepository =
        di.sl<LocalAiRepository>();

    _localModelBenchmark =
        LocalModelBenchmarkRunner(
      runtimeProvider: _runtimeProvider,
      localAiRepository: _localAiRepository,
    );

    _benchmarkScoreStore =
        LocalBenchmarkScoreStore(
      di.sl<PreferencesService>(),
    );

    RuntimeEventLog.instance.emit(
      '[DEBUG_LAB_FORENSIC_INIT] '
      'provider_type=${_runtimeProvider.runtimeType}'
      ' provider_hash=${_runtimeProvider.hashCode.toRadixString(16)}'
      ' note=fake_voice_to_llm_calls_this_provider_directly_bypassing_InferenceService_OrchestratorStateEngine_ChatRepository',
    );
  }

  Future<void> _runTest({
    required String testId,
    required Duration timeout,
    required Future<void> Function() action,
  }) async {
    if (_running) {
      return;
    }

    setState(() {
      _running = true;
      _activeTest = testId;
      _status =
          DebugLabRunStatus.running;
      _statusMessage = 'RUNNING';
    });

    RuntimeEventLog.instance.emit(
      '[DEBUG_LAB_BEGIN] test=$testId',
    );

        try {
      await action().timeout(timeout);

      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_SUCCESS] test=$testId',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status =
            DebugLabRunStatus.success;
        _statusMessage = 'SUCCESS';
      });
    } on TimeoutException catch (error, stackTrace) {
      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_TIMEOUT] '
        'test=$testId '
        'error=$error '
        'stack=$stackTrace',
      );

      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_CRASH_MARKER] '
        'test=$testId '
        'kind=timeout',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status =
            DebugLabRunStatus.timeout;
        _statusMessage = 'TIMEOUT';
      });
    } catch (error, stackTrace) {
      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_FAILED] '
        'test=$testId '
        'error=$error '
        'stack=$stackTrace',
      );

      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_CRASH_MARKER] '
        'test=$testId '
        'kind=exception',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status =
            DebugLabRunStatus.failed;
        _statusMessage = 'FAILED';
      });
    } finally {
      RuntimeEventLog.instance.emit(
        '[DEBUG_LAB_END] '
        'test=$testId '
        'status=${_status.name}',
      );

      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }
  Future<void> _runFakeVoiceToLlm() {
    return _runTest(
      testId: 'fake_voice_to_llm',
      timeout: _voiceTimeout,
      action: () async {
        const prompt = 'ciao';

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] '
          'test=fake_voice_to_llm '
          'stage=runtime_inference_only',
        );

        // ── Forensic: direct runtime path ──────────────────────
        //
        // This test calls _runtimeProvider.streamInference()
        // directly.
        //
        // It bypasses InferenceService,
        // OrchestratorStateEngine, and ChatRepository entirely.
        //
        // As a consequence, the following events are
        // intentionally absent from the log:
        //
        // PRE_STREAM_FORWARD
        // PRE_STREAM_BYPASS
        // PRE_STREAM_INFERENCE
        //
        // FIRST_TOKEN_ATTEMPT_BEGIN is emitted inside
        // AndroidFfiRuntimeProvider._runInferenceSerially and
        // WILL appear when the serial-queue action executes.

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] '
          'test=fake_voice_to_llm'
          ' dispatch_path=DIRECT_RUNTIME_PROVIDER'
          ' provider=${_runtimeProvider.runtimeType}'
          ' provider_hash=${_runtimeProvider.hashCode.toRadixString(16)}'
          ' note=bypasses_InferenceService_OrchestratorStateEngine_ChatRepository'
          ' expected_absent=PRE_STREAM_FORWARD+PRE_STREAM_BYPASS+PRE_STREAM_INFERENCE',
        );

        final selectedResult =
            await _localAiRepository
                .getSelectedModel();

        final selectedModel =
            selectedResult.fold(
          (failure) => throw StateError(
            'Selected model lookup failed: '
            '$failure',
          ),
          (model) => model,
        );

        if (selectedModel == null) {
          throw StateError(
            'No selected local model.',
          );
        }

        final modelPath =
            selectedModel.localPath
                    ?.trim() ??
                '';

        if (modelPath.isEmpty) {
          throw StateError(
            'Selected model path missing.',
          );
        }

        final sessionId =
            'debug-lab-voice-'
            '${DateTime.now().millisecondsSinceEpoch}';

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DIRECT_CALL] '
          'test=fake_voice_to_llm'
          ' target=_runtimeProvider.streamInference'
          ' sessionId=$sessionId'
          ' modelId=${selectedModel.effectiveRuntimeModelId}'
          ' modelPath=$modelPath',
        );

        final cancellationToken =
            CancellationToken();

        final streamedText =
            StringBuffer();

        String? finalChunkText;

        var chunkCount = 0;

        var firstChunkLogged = false;

        await for (
          final chunk
          in _runtimeProvider.streamInference(
            request: InferenceRequest(
              sessionId: sessionId,
              prompt: prompt,
              modelId: selectedModel
                  .effectiveRuntimeModelId,
              modelPath: modelPath,
              maxTokens: 96,
              temperature: 0.3,
            ),
            cancellationToken:
                cancellationToken,
          )
        ) {
          chunkCount++;

          if (!firstChunkLogged) {
            firstChunkLogged = true;

            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_FORENSIC_FIRST_CHUNK] '
              'test=fake_voice_to_llm'
              ' sessionId=$sessionId'
              ' isFinal=${chunk.isFinal}'
              ' isError=${chunk.isError}'
              ' text_chars=${chunk.text.length}',
            );
          }

          if (chunk.runtimeNotice !=
                  null &&
              chunk.runtimeNotice!
                  .trim()
                  .isNotEmpty) {
            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_STAGE] '
              'test=fake_voice_to_llm '
              'notice="${chunk.runtimeNotice}"',
            );
          }

          if (chunk.isError) {
            RuntimeEventLog.instance.emit(
              '[DEBUG_LAB_FORENSIC_STREAM_ERROR] '
              'test=fake_voice_to_llm'
              ' sessionId=$sessionId'
              ' error="${chunk.errorMessage}"',
            );

            throw StateError(
              chunk.errorMessage ??
                  'Runtime inference failed.',
            );
          }

          if (chunk.isFinal) {
            finalChunkText =
                chunk.text.trim();
          } else if (chunk
              .text
              .isNotEmpty) {
            streamedText.write(
              chunk.text,
            );
          }
        }

        final response =
            (finalChunkText ?? '')
                    .trim()
                    .isNotEmpty
                ? finalChunkText!.trim()
                : streamedText
                    .toString()
                    .trim();

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DIRECT_RESULT] '
          'test=fake_voice_to_llm'
          ' sessionId=$sessionId'
          ' total_chunks=$chunkCount'
          ' response_chars=${response.length}'
          ' streamed_chars=${streamedText.length}'
          ' final_chunk=${finalChunkText != null}',
        );

        if (response.isEmpty) {
          throw const FormatException(
            'Runtime returned empty response.',
          );
        }

        widget.onRenderVoiceInference(
          prompt: prompt,
          response: response,
        );
      },
    );
  }

  Future<void> _showBenchmarkLabMenu() async {
    if (_running) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101723),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget item({
          required IconData icon,
          required String title,
          required String subtitle,
          required bool available,
          VoidCallback? onTap,
        }) {
          return Card(
            color: const Color(0xFF161E2B),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              enabled: available,
              leading: Icon(
                icon,
                color: available ? Colors.lightBlueAccent : Colors.white38,
              ),
              title: Text(
                title,
                style: TextStyle(
                  color: available ? Colors.white : Colors.white54,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(
                  color: available ? Colors.white70 : Colors.white38,
                  fontSize: 12,
                ),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: available
                      ? const Color(0xFF123B2A)
                      : const Color(0xFF2B3038),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  available ? 'Disponibile' : 'Da implementare',
                  style: TextStyle(
                    color: available
                        ? const Color(0xFF6EE7A8)
                        : Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              onTap: onTap,
            ),
          );
        }

        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.88,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Benchmark Lab',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Scegli il tipo di prova. I benchmark gia esistenti '
                    'restano invariati; gli altri verranno collegati '
                    'progressivamente.',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      children: [
                        item(
                          icon: Icons.account_tree_outlined,
                          title: 'Benchmark Orchestratore',
                          subtitle:
                              'Test di ruolo attuale. Selezione modelli e '
                              'punteggio ruolo nel prossimo step.',
                          available: true,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(
                              _showOrchestratorBenchmarkModelPicker(),
                            );
                          },
                        ),
                        item(
                          icon: Icons.bolt_outlined,
                          title: 'Benchmark rapido',
                          subtitle:
                              'Tutti i modelli pronti, pochi test '
                              'rappresentativi e primo General Score.',
                          available: true,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_runQuickGeneralBenchmark());
                          },
                        ),
                        item(
                          icon: Icons.fact_check_outlined,
                          title: 'Benchmark qualita',
                          subtitle:
                              'Suite completa: accuratezza, istruzioni, '
                              'contesto e hallucination.',
                          available: false,
                        ),
                        item(
                          icon: Icons.speed_outlined,
                          title: 'Benchmark performance',
                          subtitle:
                              'First token, prefill, decode, warm/cold e '
                              'tempo totale.',
                          available: false,
                        ),
                        item(
                          icon: Icons.memory_outlined,
                          title: 'Vulkan 0 / 10 / 99',
                          subtitle:
                              'Confronto CPU, offload parziale e massimo '
                              'offload GPU.',
                          available: true,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(
                              _showVulkanBenchmarkModelPicker(),
                            );
                          },
                        ),
                        item(
                          icon: Icons.thermostat_outlined,
                          title: 'Stress termico',
                          subtitle:
                              'Run prolungato con temperatura, memoria e '
                              'stabilita.',
                          available: false,
                        ),
                        item(
                          icon: Icons.storage_outlined,
                          title: 'Memoria / Context',
                          subtitle:
                              'Contesti crescenti, KV cache, recovery e '
                              'pressione memoria.',
                          available: false,
                        ),
                        item(
                          icon: Icons.translate_outlined,
                          title: 'Multilingua',
                          subtitle:
                              'Confronto coerente in italiano, inglese, '
                              'francese e spagnolo.',
                          available: false,
                        ),
                        item(
                          icon: Icons.shield_outlined,
                          title: 'Stabilita',
                          subtitle:
                              'Inferenze consecutive, session reuse, switch '
                              'modello e cancellazione.',
                          available: false,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _runQuickGeneralBenchmark() async {
    List<AiModel> candidates;
    try {
      candidates = await _localModelBenchmark.loadBenchmarkCandidates();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossibile caricare i modelli: $error'),
        ),
      );
      return;
    }

    final runnable = candidates
        .where(LocalModelBenchmarkRunner.isRunnableCandidate)
        .toList(growable: false);

    if (runnable.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nessun modello locale pronto per il benchmark.'),
        ),
      );
      return;
    }

    LocalModelBenchmarkReport? report;

    await _runTest(
      testId: 'local_model_quick_benchmark',
      timeout: Duration(
        minutes: (runnable.length * 4).clamp(8, 60).toInt(),
      ),
      action: () async {
        report = await _localModelBenchmark.run(
          modelIds: runnable.map((model) => model.id),
          benchmarkCases: LocalModelBenchmarkRunner.quickCases,
          continueOnModelError: true,
          onProgress: (message) {
            if (!mounted) return;
            setState(() {
              _statusMessage = 'Rapido • $message';
            });
          },
        );

        final completed = report;
        if (completed == null) return;

        final byId = <String, AiModel>{
          for (final model in runnable) model.id: model,
        };

        for (final result in completed.models) {
          final catalogId = result.catalogModelId ?? result.modelId;
          final model = byId[catalogId];
          if (model == null) continue;

          await _benchmarkScoreStore.saveComponent(
            model: model,
            component: LocalBenchmarkComponent.quick,
            score: LocalBenchmarkScoring.quickScore(result),
            updatedAt: completed.createdAt,
          );
        }
      },
    );

    if (report == null || !mounted) return;
    await _showQuickBenchmarkReport(report!);
  }

  Future<void> _showQuickBenchmarkReport(
    LocalModelBenchmarkReport report,
  ) async {
    final buffer = StringBuffer()
      ..writeln('BENCHMARK RAPIDO')
      ..writeln('created_at=${report.createdAt.toIso8601String()}')
      ..writeln();

    for (final model in report.models) {
      buffer
        ..writeln('${model.displayName} [${model.modelId}]')
        ..writeln(
          'general_quick_score=${LocalBenchmarkScoring.quickScore(model)}/100',
        )
        ..writeln('quality=${model.score}/${model.maxScore}')
        ..writeln(
          'avg_first_content_ms=${model.averageFirstContentMs.toStringAsFixed(0)}',
        )
        ..writeln(
          'avg_decode_tokens_s=${model.averageDecodeTokensPerSecond.toStringAsFixed(2)}',
        )
        ..writeln();
    }

    if (report.failures.isNotEmpty) {
      buffer.writeln('MODELLI NON COMPLETATI');
      for (final failure in report.failures) {
        buffer.writeln(
          '- ${failure.displayName} [${failure.modelId}]: ${failure.error}',
        );
      }
      buffer.writeln();
    }
    final text = buffer.toString().trimRight();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF101723),
          title: const Text(
            'Benchmark rapido',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Chiudi'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Benchmark rapido copiato negli appunti'),
                  ),
                );
              },
              child: const Text('Copia'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showOrchestratorBenchmarkModelPicker() async {
    final modelIds = await _pickBenchmarkModels(
      title: 'Benchmark Orchestratore',
      subtitle:
          'Scegli i modelli da confrontare nel ruolo Orchestratore.',
      defaultModelIds:
          LocalModelBenchmarkRunner.defaultOrchestratorTargetModelIds,
    );
    if (modelIds == null || modelIds.isEmpty || !mounted) return;
    await _runLocalModelBenchmark(modelIds: modelIds);
  }

  Future<void> _showVulkanBenchmarkModelPicker() async {
    final modelIds = await _pickBenchmarkModels(
      title: 'Vulkan 0 / 10 / 99',
      subtitle:
          'Scegli uno o più modelli. Per ciascuno verranno provati '
          'CPU, offload parziale e massimo offload GPU.',
      defaultModelIds:
          LocalModelBenchmarkRunner.defaultOrchestratorTargetModelIds,
    );
    if (modelIds == null || modelIds.isEmpty || !mounted) return;
    await _runVulkanLayerSweep(modelIds: modelIds);
  }

  Future<List<String>?> _pickBenchmarkModels({
    required String title,
    required String subtitle,
    required Iterable<String> defaultModelIds,
  }) async {
    if (_running) return null;

    List<AiModel> candidates;
    try {
      candidates = await _localModelBenchmark.loadBenchmarkCandidates();
    } catch (error) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossibile caricare i modelli: $error'),
        ),
      );
      return null;
    }

    if (!mounted) return null;

    final scores = await _benchmarkScoreStore.loadForModels(candidates);
    if (!mounted) return null;

    final defaults = defaultModelIds.toSet();
    final selected = <String>{};

    void applyDefaults() {
      selected.clear();
      for (final candidate in candidates) {
        if (defaults.contains(candidate.id) &&
            LocalModelBenchmarkRunner.isRunnableCandidate(candidate)) {
          selected.add(candidate.id);
        }
      }
      if (selected.isEmpty) {
        for (final candidate in candidates) {
          if (LocalModelBenchmarkRunner.isRunnableCandidate(candidate)) {
            selected.add(candidate.id);
            break;
          }
        }
      }
    }

    applyDefaults();

    return showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: const Color(0xFF101723),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final runnableCount = candidates
                .where(LocalModelBenchmarkRunner.isRunnableCandidate)
                .length;

            void selectDefaults() {
              setSheetState(applyDefaults);
            }

            void selectAllRunnable() {
              setSheetState(() {
                selected
                  ..clear()
                  ..addAll(
                    candidates
                        .where(
                          LocalModelBenchmarkRunner.isRunnableCandidate,
                        )
                        .map((model) => model.id),
                  );
              });
            }

            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.92,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$runnableCount/${candidates.length} modelli pronti • '
                        '${selected.length} selezionati',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton(
                            onPressed: selectDefaults,
                            child: const Text('Predefiniti'),
                          ),
                          OutlinedButton(
                            onPressed: runnableCount == 0
                                ? null
                                : selectAllRunnable,
                            child: const Text('Tutti scaricati'),
                          ),
                          TextButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () => setSheetState(selected.clear),
                            child: const Text('Nessuno'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: ListView.builder(
                          itemCount: candidates.length,
                          itemBuilder: (context, index) {
                            final model = candidates[index];
                            final runnable = LocalModelBenchmarkRunner
                                .isRunnableCandidate(model);
                            final checked = selected.contains(model.id);
                            final size = model.sizeCategory?.trim();
                            final sourceLabel = switch (model.source) {
                              'local_import' => 'Importato',
                              'custom_url' => 'URL personalizzato',
                              _ => 'Catalogo',
                            };
                            final stateLabel = runnable
                                ? 'Pronto'
                                : model.isDownloaded
                                    ? 'Non valido'
                                    : 'Non scaricato';
                            final storedScore = scores[model.id];
                            final scoreLabel = storedScore?.generalScore == null
                                ? 'Punteggio generale: —'
                                : 'Punteggio generale: '
                                    '${storedScore!.generalScore}/100 • '
                                    '${storedScore.completedComponents}/'
                                    '${LocalModelBenchmarkScore.totalComponents} suite';


                            return Card(
                              color: const Color(0xFF161E2B),
                              margin: const EdgeInsets.only(bottom: 7),
                              child: CheckboxListTile(
                                value: checked,
                                enabled: runnable,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  model.displayName,
                                  style: TextStyle(
                                    color: runnable
                                        ? Colors.white
                                        : Colors.white38,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '${size == null || size.isEmpty ? "Dimensione n/d" : size}'
                                  ' • $sourceLabel • $stateLabel\n'
                                  '$scoreLabel',
                                  style: TextStyle(
                                    color: runnable
                                        ? Colors.white60
                                        : Colors.white30,
                                    fontSize: 11,
                                  ),
                                ),
                                onChanged: !runnable
                                    ? null
                                    : (value) {
                                        setSheetState(() {
                                          if (value == true) {
                                            selected.add(model.id);
                                          } else {
                                            selected.remove(model.id);
                                          }
                                        });
                                      },
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: selected.isEmpty
                            ? null
                            : () {
                                final chosenIds = candidates
                                    .where(
                                      (model) => selected.contains(model.id),
                                    )
                                    .map((model) => model.id)
                                    .toList(growable: false);
                                Navigator.of(sheetContext).pop(chosenIds);
                              },
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                          selected.isEmpty
                              ? 'Seleziona almeno un modello'
                              : 'Avvia test (${selected.length})',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Duration _orchestratorBenchmarkTimeoutFor(
    Iterable<String>? modelIds,
  ) {
    final modelCount = modelIds?.length ??
        LocalModelBenchmarkRunner.defaultOrchestratorTargetModelIds.length;
    final minutes = (modelCount * 6)
        .clamp(_benchmarkTimeout.inMinutes, 60)
        .toInt();
    return Duration(minutes: minutes);
  }
  Future<void> _runLocalModelBenchmark({
    Iterable<String>? modelIds,
  }) async {
    LocalModelBenchmarkReport? report;

    await _runTest(
      testId: 'local_model_benchmark',
      timeout: _orchestratorBenchmarkTimeoutFor(modelIds),
      action: () async {
        report = await _localModelBenchmark.run(
          modelIds: modelIds,
          onProgress: (message) {
            if (!mounted) {
              return;
            }
            setState(() {
              _statusMessage = message;
            });
          },
        );
      },
    );

    if (report == null || !mounted) {
      return;
    }

    await _showLocalModelBenchmarkReport(report!);
  }

  Duration _vulkanSweepTimeoutFor(
    Iterable<String>? modelIds,
  ) {
    final modelCount = modelIds?.length ??
        LocalModelBenchmarkRunner.defaultOrchestratorTargetModelIds.length;
    final minutes = (modelCount * 10)
        .clamp(_vulkanSweepTimeout.inMinutes, 90)
        .toInt();
    return Duration(minutes: minutes);
  }

  Future<void> _runVulkanLayerSweep({
    Iterable<String>? modelIds,
  }) async {
    VulkanLayerSweepReport? report;

    await _runTest(
      testId: 'vulkan_layer_sweep_0_10_99',
      timeout: _vulkanSweepTimeoutFor(modelIds),
      action: () async {
        report = await _localModelBenchmark.runVulkanLayerSweep(
          modelIds: modelIds,
          onProgress: (message) {
            if (!mounted) return;
            setState(() {
              _statusMessage = message;
            });
          },
        );
      },
    );

    if (report == null || !mounted) return;
    await _showVulkanLayerSweepReport(report!);
  }

  Future<void> _showVulkanLayerSweepReport(
    VulkanLayerSweepReport report,
  ) async {
    final text = report.toPlainText();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF101723),
          title: const Text(
            'Vulkan 0 / 10 / 99',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 440,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Chiudi'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Sweep Vulkan copiato negli appunti'),
                  ),
                );
              },
              child: const Text('Copia'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showLocalModelBenchmarkReport(
    LocalModelBenchmarkReport report,
  ) async {
    final text = report.toPlainText();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF101723),
          title: const Text(
            'Benchmark Orchestratore',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 440,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Chiudi'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: text),
                );
                if (!dialogContext.mounted) {
                  return;
                }
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Benchmark copiato negli appunti'),
                  ),
                );
              },
              child: const Text('Copia'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _runFakeChatMessage() {
    return _runTest(
      testId: 'fake_chat_message',
      timeout: _chatTimeout,
      action: () async {
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] '
          'test=fake_chat_message '
          'stage=dispatch_send_event',
        );

        // ── Forensic: fire-and-forget chat pipeline dispatch ───
        //
        // onSendThroughChatPipeline
        //   → ChatPage._onSend
        //   → OrchestratorStateEngine.add(SendMessageEvent)
        //   → ChatRepositoryImpl.sendMessage
        //   → Orchestrator.handleStream
        //   → InferenceService.stream
        //   → runtimeProvider.streamInference.
        //
        // The action returns after a 250 ms yield; inference
        // continues asynchronously.

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] '
          'test=fake_chat_message'
          ' dispatch_path=CHAT_PIPELINE_FIRE_AND_FORGET'
          ' note=dispatches_SendMessageEvent_returns_after_250ms_inference_runs_async_PRE_STREAM_events_appear_after_SUCCESS',
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_chat_message'
          ' target=onSendThroughChatPipeline'
          ' stage=pre_invoke',
        );

        widget.onSendThroughChatPipeline(
          'Debug Lab test: rispondi con un saluto breve e gentile.',
          const <ChatAttachment>[],
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_chat_message'
          ' target=onSendThroughChatPipeline'
          ' stage=post_return'
          ' note=callback_returned_synchronously_inference_continues_in_background',
        );

        await Future<void>.delayed(
          const Duration(
            milliseconds: 250,
          ),
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_chat_message'
          ' stage=250ms_yield_complete_action_exiting_without_inference_result',
        );
      },
    );
  }

  Future<void> _runFakeVisionRequest() {
    return _runTest(
      testId: 'fake_vision_request',
      timeout: _visionTimeout,
      action: () async {
        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] '
          'test=fake_vision_request '
          'stage=load_local_asset',
        );

        final bytesData =
            await rootBundle.load(
          _assetImagePath,
        );

        final bytes =
            bytesData.buffer.asUint8List(
          bytesData.offsetInBytes,
          bytesData.lengthInBytes,
        );

        final tempDirectory =
            await getTemporaryDirectory();

        final imageFile = File(
          '${tempDirectory.path}/'
          'debug_lab_test_image_'
          '${DateTime.now().millisecondsSinceEpoch}'
          '.png',
        );

        await imageFile.writeAsBytes(
          bytes,
          flush: true,
        );

        final attachment =
            ChatAttachment(
          id:
              'debug-lab-vision-'
              '${DateTime.now().millisecondsSinceEpoch}',
          type:
              ChatAttachmentType.image,
          path: imageFile.path,
          name:
              'debug_lab_test_image.png',
          mimeType: 'image/png',
          sizeBytes: bytes.length,
          thumbnailPath:
              imageFile.path,
          uploadState:
              ChatAttachmentUploadState
                  .ready,
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_STAGE] '
          'test=fake_vision_request '
          'stage=dispatch_with_attachment '
          'path=${imageFile.path}',
        );

        // ── Forensic: fire-and-forget chat pipeline dispatch ───
        //
        // Same dispatch path as fake_chat_message but with an
        // image attachment.

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC] '
          'test=fake_vision_request'
          ' dispatch_path=CHAT_PIPELINE_FIRE_AND_FORGET'
          ' attachment_bytes=${bytes.length}'
          ' note=dispatches_SendMessageEvent_with_image_returns_after_250ms_inference_runs_async_PRE_STREAM_events_appear_after_SUCCESS',
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_vision_request'
          ' target=onSendThroughChatPipeline'
          ' stage=pre_invoke'
          ' attachments=1',
        );

        widget.onSendThroughChatPipeline(
          'Debug Lab vision test: '
          'descrivi questa immagine di test.',
          <ChatAttachment>[
            attachment,
          ],
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_vision_request'
          ' target=onSendThroughChatPipeline'
          ' stage=post_return'
          ' note=callback_returned_synchronously_inference_continues_in_background',
        );

        await Future<void>.delayed(
          const Duration(
            milliseconds: 250,
          ),
        );

        RuntimeEventLog.instance.emit(
          '[DEBUG_LAB_FORENSIC_DISPATCH] '
          'test=fake_vision_request'
          ' stage=250ms_yield_complete_action_exiting_without_inference_result',
        );
      },
    );
  }

  /// Restituisce soltanto le ultime righe del log persistente.
  ///
  /// Evita di riempire gli appunti del telefono con megabyte di
  /// diagnostica appartenente a sessioni precedenti.
  String _latestPersistedLogLines(
    String logText, {
    int maxLines =
        _persistedLogCopyLines,
  }) {
    final normalized =
        logText.trim();

    if (normalized.isEmpty) {
      return normalized;
    }

    final lines =
        normalized.split('\n');

    if (lines.length <= maxLines) {
      return normalized;
    }

    final firstLine =
        lines.length - maxLines;

    return lines
        .sublist(firstLine)
        .join('\n');
  }

  Future<void> _copyLatestPersistedLog(
    BuildContext dialogContext,
    String logText,
  ) async {
    final text =
        _latestPersistedLogLines(
      logText,
    );

    await Clipboard.setData(
      ClipboardData(
        text: text,
      ),
    );

    if (!dialogContext.mounted) {
      return;
    }

    ScaffoldMessenger.of(
      dialogContext,
    ).showSnackBar(
      const SnackBar(
        content: Text(
          'Ultimi eventi copiati negli appunti',
        ),
        duration:
            Duration(seconds: 2),
      ),
    );
  }

  Future<void> _clearPersistedLog(
    BuildContext dialogContext,
  ) async {
    await RuntimeEventLog.instance
        .clearPersistedLog();

    // Azzera anche il buffer diagnostico della sessione corrente,
    // così il nuovo test parte realmente da una situazione pulita.
    RuntimeEventLog.instance.clear();

    if (!dialogContext.mounted) {
      return;
    }

    Navigator.of(
      dialogContext,
    ).pop();

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      const SnackBar(
        content: Text(
          'Log crash azzerato. '
          'Ora riproduci il problema una sola volta.',
        ),
        duration:
            Duration(seconds: 3),
      ),
    );
  }

  /// Shows the persisted on-disk crash log.
  ///
  /// Unlike the in-memory RuntimeEventLog buffer, this survives a
  /// native crash that terminates the Android process.
  Future<void> _showPersistedLog() async {
    final logText =
        await RuntimeEventLog.instance
            .readPersistedLog();

    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (
        dialogContext,
      ) {
        return AlertDialog(
          backgroundColor:
              const Color(
            0xFF101723,
          ),
          title: const Text(
            'Log crash persistente',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child:
                SingleChildScrollView(
              child: SelectableText(
                logText,
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                  fontSize: 11,
                  fontFamily:
                      'monospace',
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(
                dialogContext,
              ).pop(),
              child:
                  const Text(
                'Chiudi',
              ),
            ),
            TextButton(
              style:
                  TextButton.styleFrom(
                foregroundColor:
                    Colors.redAccent,
              ),
              onPressed: () =>
                  _clearPersistedLog(
                dialogContext,
              ),
              child:
                  const Text(
                'Azzera log',
              ),
            ),
            FilledButton(
              onPressed: () =>
                  _copyLatestPersistedLog(
                dialogContext,
                logText,
              ),
              child: const Text(
                'Copia ultimi 200',
              ),
            ),
          ],
        );
      },
    );
  }

  Color _statusColor(
    DebugLabRunStatus status,
  ) {
    switch (status) {
      case DebugLabRunStatus.idle:
        return const Color(
          0xFF9CA3AF,
        );

      case DebugLabRunStatus.running:
        return const Color(
          0xFFFBBF24,
        );

      case DebugLabRunStatus.success:
        return const Color(
          0xFF4ADE80,
        );

      case DebugLabRunStatus.failed:
        return const Color(
          0xFFF87171,
        );

      case DebugLabRunStatus.timeout:
        return const Color(
          0xFFFB923C,
        );
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final statusColor =
        _statusColor(_status);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 250,
        padding:
            const EdgeInsets.all(
          10,
        ),
        decoration: BoxDecoration(
          color: const Color(
            0xFF090D14,
          ).withValues(
            alpha: 0.96,
          ),
          borderRadius:
              BorderRadius.circular(
            12,
          ),
          border: Border.all(
            color:
                Colors.white24,
          ),
          boxShadow:
              const <BoxShadow>[
            BoxShadow(
              color:
                  Color(0x66000000),
              blurRadius: 10,
              offset:
                  Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment
                  .stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'DEBUG LAB',
                    style:
                        TextStyle(
                      color:
                          Colors.white,
                      fontWeight:
                          FontWeight
                              .w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity:
                      VisualDensity
                          .compact,
                  splashRadius: 16,
                  onPressed:
                      _running
                          ? null
                          : DebugLabController
                              .instance
                              .close,
                  icon:
                      const Icon(
                    Icons.close,
                    color: Colors
                        .white70,
                    size: 16,
                  ),
                ),
              ],
            ),
            Container(
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              decoration:
                  BoxDecoration(
                color: Colors.black
                    .withValues(
                  alpha: 0.24,
                ),
                borderRadius:
                    BorderRadius
                        .circular(
                  8,
                ),
              ),
              child: Text(
                '$_statusMessage • '
                '$_activeTest',
                style: TextStyle(
                  color:
                      statusColor,
                  fontSize: 10,
                  fontWeight:
                      FontWeight
                          .w600,
                ),
              ),
            ),
            const SizedBox(
              height: 8,
            ),
            FilledButton(
              onPressed:
                  _running
                      ? null
                      : _runFakeVoiceToLlm,
              child:
                  const Text(
                'Fake Voice → LLM',
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            FilledButton.icon(
              onPressed:
                  _running
                      ? null
                      : _showBenchmarkLabMenu,
              icon:
                  const Icon(
                Icons.science_outlined,
              ),
              label:
                  const Text(
                'Benchmark Lab',
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            FilledButton(
              onPressed:
                  _running
                      ? null
                      : _runFakeChatMessage,
              child:
                  const Text(
                'Fake Chat Message',
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            FilledButton(
              onPressed:
                  _running
                      ? null
                      : _runFakeVisionRequest,
              child:
                  const Text(
                'Fake Vision Request',
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            FilledButton(
              onPressed:
                  _running
                      ? null
                      : widget
                          .onClearChat,
              child:
                  const Text(
                'Clear Chat',
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            FilledButton(
              style:
                  FilledButton
                      .styleFrom(
                backgroundColor:
                    const Color(
                  0xFF7C3AED,
                ),
              ),
              onPressed:
                  _showPersistedLog,
              child:
                  const Text(
                'Mostra log crash',
              ),
            ),
            const SizedBox(
              height: 8,
            ),
            DropdownButtonFormField<
                AssistantMessageTextSize>(
              initialValue:
                  widget
                      .assistantTextSize,
              isExpanded: true,
              decoration:
                  const InputDecoration(
                filled: true,
                fillColor:
                    Color(
                  0x1AFFFFFF,
                ),
                border:
                    OutlineInputBorder(),
                isDense: true,
                labelText:
                    'Text Size',
                labelStyle:
                    TextStyle(
                  color:
                      Colors.white70,
                  fontSize: 12,
                ),
              ),
              dropdownColor:
                  const Color(
                0xFF101723,
              ),
              style:
                  const TextStyle(
                color: Colors.white,
              ),
              items:
                  AssistantMessageTextSize
                      .values
                      .map(
                (
                  size,
                ) =>
                    DropdownMenuItem<
                        AssistantMessageTextSize>(
                  value: size,
                  child: Text(
                    '${size.name[0].toUpperCase()}'
                    '${size.name.substring(1)}',
                  ),
                ),
              ).toList(
                growable: false,
              ),
              onChanged:
                  _running
                      ? null
                      : (
                          size,
                        ) {
                          if (size ==
                              null) {
                            return;
                          }

                          widget
                              .onAssistantTextSizeChanged(
                            size,
                          );
                        },
            ),
          ],
        ),
      ),
    );
  }
}
