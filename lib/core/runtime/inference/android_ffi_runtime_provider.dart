import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_exceptions.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Statistiche memoria
class MemoryStats {
  final int dartHeapBytes;
  final int rssBytes;
  final int systemTotalBytes;
  final int systemAvailBytes;
  final bool isLowMemory;
  final DateTime timestamp;

  const MemoryStats({
    this.dartHeapBytes = 0,
    this.rssBytes = 0,
    this.systemTotalBytes = 0,
    this.systemAvailBytes = 0,
    this.isLowMemory = false,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'rssMB': (rssBytes / 1024 / 1024).toStringAsFixed(2),
        'systemAvailMB': (systemAvailBytes / 1024 / 1024).toStringAsFixed(2),
        'lowMemory': isLowMemory,
      };
}

enum _WorkerCommand { loadModel, startGeneration, cancel, freeModel, dispose, heartbeat }

class _WorkerMessage {
  final _WorkerCommand command;
  final dynamic data;
  final SendPort? replyPort;
  const _WorkerMessage(this.command, {this.data, this.replyPort});
}

class AndroidFfiRuntimeProvider extends LocalRuntimeProvider {
  AndroidFfiRuntimeProvider({
    RuntimeStateMachine? runtimeStateMachine,
    bool Function()? developerModeProvider,
  })  : runtimeStateMachine = runtimeStateMachine ?? RuntimeStateMachine(),
        _developerModeProvider = developerModeProvider ?? (() => false),
        super(developerModeProvider: developerModeProvider);

  static const _logTag = 'AI_RUNTIME';
  static const int _safeMaxTokens = 128;
  static const int _maxOutputChars = 32000;
  static const Duration _generationTimeout = Duration(seconds: 90);
  static const Duration _modelLoadTimeout = Duration(seconds: 60);
  static const Duration _heartbeatInterval = Duration(seconds: 10);

  static const MethodChannel _memoryChannel = MethodChannel('ai_orchestrator/memory');

  final LocalRuntimeMonitor monitor = LocalRuntimeMonitor();
  final RuntimeStateMachine runtimeStateMachine;
  final bool Function() _developerModeProvider;

  bool get _isDeveloperMode => _developerModeProvider();

  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  String? _loadedModelPath;
  bool _workerBusy = false;
  Timer? _heartbeatTimer;
  final Set<String> _activeSessions = <String>{};
  Future<void> _inferenceTail = Future<void>.value();

  static void _safeLog(String message) {
    try {
      debugPrint('[$_logTag] $message');
      RuntimeEventLog.instance.emit(message);
    } catch (_) {}
  }

  static void _safeAdd(StreamController<InferenceResponse> controller, InferenceResponse response) {
    if (controller.isClosed) return;
    try {
      controller.add(response);
    } catch (_) {}
  }

  // ── Monitoraggio Memoria ─────────────────────────────────────────────────
  Future<MemoryStats> getMemoryStats() async {
    try {
      final native = await _getNativeMemoryInfo();
      return MemoryStats(
        rssBytes: native['rss'] ?? ProcessInfo.currentRss,
        systemTotalBytes: native['total'] ?? 0,
        systemAvailBytes: native['avail'] ?? 0,
        isLowMemory: native['lowMemory'] ?? false,
        timestamp: DateTime.now(),
      );
    } catch (_) {
      return MemoryStats(timestamp: DateTime.now());
    }
  }

  Future<Map<String, dynamic>> _getNativeMemoryInfo() async {
    try {
      final result = await _memoryChannel.invokeMethod<Map>('getMemoryInfo');
      return result ?? {};
    } catch (_) {
      return {};
    }
  }

  void _logMemory(String context) async {
    final stats = await getMemoryStats();
    _safeLog('[MEMORY][$context] ${stats.toJson()}');
    monitor.updateMemoryStats(stats);
  }

  // ── Supervisor ───────────────────────────────────────────────────────────
  void _startSupervisor() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _checkWorkerHealth());
  }

  Future<void> _checkWorkerHealth() async {
    if (_workerSendPort == null || _workerBusy) return;
    try {
      final port = ReceivePort();
      _workerSendPort!.send(_WorkerMessage(_WorkerCommand.heartbeat, replyPort: port.sendPort));
      await port.first.timeout(const Duration(seconds: 6));
      port.close();
    } catch (_) {
      _safeLog('[SUPERVISOR] Worker unresponsive - restarting');
      await _restartWorker();
    }
  }

  Future<void> _restartWorker() async {
    _disposeWorker();
    await _ensureWorkerIsolate();
  }

  // ── Worker Management ────────────────────────────────────────────────────
  Future<void> _ensureWorkerIsolate() async {
    if (_workerIsolate != null && _workerSendPort != null) return;

    final receivePort = ReceivePort();
    _workerIsolate = await Isolate.spawn(
      _runtimeWorkerEntryPoint,
      receivePort.sendPort,
      errorsAreFatal: false,
    );

    final completer = Completer<SendPort>();
    receivePort.listen((msg) {
      if (msg is SendPort) completer.complete(msg);
    });

    _workerSendPort = await completer.future.timeout(const Duration(seconds: 10));
    _startSupervisor();
    _safeLog('[WORKER] Isolate ready');
  }

  void _disposeWorker() {
    _heartbeatTimer?.cancel();
    _workerSendPort?.send(_WorkerMessage(_WorkerCommand.dispose));
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;
    _loadedModelPath = null;
  }

  // ── Persistent Model + Inference ─────────────────────────────────────────
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();
    bool terminalSent = false;

    () async {
      await _runInferenceSerially(() async {
        final sessionId = request.sessionId.trim().isEmpty ? 'unknown' : request.sessionId.trim();
        if (!_claimSession(sessionId)) return;

        try {
          await _ensureWorkerIsolate();
          _logMemory('before_inference');

          final modelPath = request.modelPath!;
          final modelId = request.modelId!;

          // Persistent Model
          if (_loadedModelPath != modelPath) {
            _safeLog('[MODEL] Loading new model: $modelPath');
            final loadPort = ReceivePort();
            _workerSendPort!.send(_WorkerMessage(_WorkerCommand.loadModel,
                data: modelPath, replyPort: loadPort.sendPort));
            if (await loadPort.first != 0) throw Exception('Model load failed');
            loadPort.close();
            _loadedModelPath = modelPath;
          }

          // Start Generation
          final prompt = _composePrompt(request, modelId: modelId);
          final maxTokens = request.maxTokens.clamp(1, _safeMaxTokens);
          final streamPort = ReceivePort();

          final startPort = ReceivePort();
          _workerSendPort!.send(_WorkerMessage(_WorkerCommand.startGeneration,
              data: {
                'prompt': prompt,
                'maxTokens': maxTokens,
                'temperature': request.temperature,
                'streamPort': streamPort.sendPort,
              },
              replyPort: startPort.sendPort));

          if (await startPort.first != 0) throw Exception('Start generation failed');
          startPort.close();

          cancellationToken.onCancel(() => _workerSendPort?.send(_WorkerMessage(_WorkerCommand.cancel)));

          await for (final event in streamPort) {
            if (controller.isClosed) break;
            if (event is! Map<String, dynamic>) continue;

            if (event['type'] == 'token') {
              _safeAdd(controller, InferenceResponse.token(text: event['text'], model: modelId));
            } else if (event['type'] == 'final') {
              if (!terminalSent) {
                terminalSent = true;
                _safeAdd(controller, InferenceResponse.finalChunk(
                  text: event['text'] ?? '',
                  tokensGenerated: event['tokens'] ?? 0,
                  model: modelId,
                ));
              }
              break;
            } else if (event['type'] == 'error') {
              if (!terminalSent) _safeAdd(controller, InferenceResponse.error(event['message'] ?? 'Error'));
              break;
            }
          }
        } catch (e) {
          _safeLog('[INFERENCE_ERROR] $e');
          if (!terminalSent) _safeAdd(controller, InferenceResponse.error(e.toString()));
        } finally {
          await _ackFreeModel(); // Solo cleanup leggero, model resta residente
          _logMemory('after_inference');
          _releaseSession(sessionId);
          if (!controller.isClosed) await controller.close().catchError((_) {});
        }
      });
    }();

    return controller.stream;
  }

  Future<void> _ackFreeModel() async {
    if (_workerSendPort == null) return;
    final port = ReceivePort();
    try {
      _workerSendPort!.send(_WorkerMessage(_WorkerCommand.freeModel, replyPort: port.sendPort));
      await port.first.timeout(const Duration(seconds: 4));
    } catch (_) {} finally {
      port.close();
    }
  }

  Future<void> _runInferenceSerially(Future<void> Function() action) async {
    final previous = _inferenceTail;
    _inferenceTail = previous.then((_) => action()).catchError((_) {});
    await _inferenceTail;
  }

  bool _claimSession(String id) {
    if (_activeSessions.contains(id)) return false;
    _activeSessions.add(id);
    return true;
  }

  void _releaseSession(String id) => _activeSessions.remove(id);

  String _composePrompt(InferenceRequest request, {required String modelId}) {
    return LocalPromptTemplates.compose(
      modelId: modelId,
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _disposeWorker();
    super.dispose();
  }
}
