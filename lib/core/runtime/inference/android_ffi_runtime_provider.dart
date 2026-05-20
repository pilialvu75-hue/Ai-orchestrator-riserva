import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';

enum WorkerState { idle, ready, generating, degraded, recovering, failed }

class MemoryStats {
  final int rssBytes;
  final int kvCacheBytes;
  final int mmapBytes;
  final bool isLowMemory;
  final double fragmentationScore;
  final DateTime timestamp;

  const MemoryStats({
    this.rssBytes = 0,
    this.kvCacheBytes = 0,
    this.mmapBytes = 0,
    this.isLowMemory = false,
    this.fragmentationScore = 0.0,
    required this.timestamp,
  });
}

enum _WorkerCommand {
  loadModel,
  startGeneration,
  cancel,
  freeModel,
  dispose,
  heartbeat
}

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

  static const _logTag = 'AI_RUNTIME_V5_LITE';

  static const int _safeMaxTokens = 128;
  static const Duration _heartbeatInterval = Duration(seconds: 8);

  static const MethodChannel _memoryChannel =
      MethodChannel('ai_orchestrator/memory');

  final RuntimeStateMachine runtimeStateMachine;
  final bool Function() _developerModeProvider;

  Isolate? _worker;
  SendPort? _sendPort;

  String? _loadedModelPath;

  Timer? _heartbeat;

  bool _isInferenceActive = false;
  bool _isRestarting = false;

  final Set<String> _activeSessions = {};

  Future<void> _queue = Future.value();

  WorkerState _state = WorkerState.idle;

  // ─────────────────────────────────────────────────────────────
  // LOG
  // ─────────────────────────────────────────────────────────────
  static void _log(String msg) {
    debugPrint('[$_logTag] $msg');
    RuntimeEventLog.instance.emit(msg);
  }

  static void _emit(StreamController<InferenceResponse> c, InferenceResponse r) {
    if (!c.isClosed) c.add(r);
  }

  // ─────────────────────────────────────────────────────────────
  // MEMORY (SAFE)
  // ─────────────────────────────────────────────────────────────
  Future<MemoryStats> _memory() async {
    try {
      final native =
          await _memoryChannel.invokeMethod<Map>('getMemoryInfo') ?? {};

      final kv = native['kvCache'] ?? 0;
      final mmap = native['mmap'] ?? 0;
      final rss = native['rss'] ?? 0;

      final frag = kv > 0 ? (kv / (kv + mmap + 1)).clamp(0.0, 1.0) : 0.0;

      return MemoryStats(
        rssBytes: rss,
        kvCacheBytes: kv,
        mmapBytes: mmap,
        isLowMemory: native['lowMemory'] ?? false,
        fragmentationScore: frag,
        timestamp: DateTime.now(),
      );
    } catch (_) {
      return MemoryStats(timestamp: DateTime.now());
    }
  }

  void _policy(MemoryStats s) {
    if (_isInferenceActive) return;

    if (s.isLowMemory || s.fragmentationScore > 0.80) {
      _log('[POLICY] degradation triggered');
      _safeRestart();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // WORKER LIFECYCLE
  // ─────────────────────────────────────────────────────────────
  Future<void> _ensureWorker() async {
    if (_worker != null && _sendPort != null) return;

    final rp = ReceivePort();

    _worker = await Isolate.spawn(_entry, rp.sendPort);

    final c = Completer<SendPort>();
    rp.listen((m) {
      if (m is SendPort) c.complete(m);
    });

    _sendPort = await c.future;
    _state = WorkerState.ready;

    _startHeartbeat();
  }

  void _disposeWorker() {
    _heartbeat?.cancel();

    _sendPort?.send(_WorkerMessage(_WorkerCommand.dispose));

    _worker?.kill(priority: Isolate.immediate);

    _worker = null;
    _sendPort = null;
    _loadedModelPath = null;

    _state = WorkerState.idle;
  }

  Future<void> _safeRestart() async {
    if (_isRestarting || _isInferenceActive) return;

    _isRestarting = true;

    try {
      _disposeWorker();
      await _ensureWorker();
    } finally {
      _isRestarting = false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // HEARTBEAT
  // ─────────────────────────────────────────────────────────────
  void _startHeartbeat() {
    _heartbeat?.cancel();

    _heartbeat = Timer.periodic(_heartbeatInterval, (_) async {
      if (_sendPort == null || _isRestarting) return;

      try {
        final rp = ReceivePort();

        _sendPort!.send(
          _WorkerMessage(_WorkerCommand.heartbeat, replyPort: rp.sendPort),
        );

        await rp.first.timeout(const Duration(seconds: 5));

        rp.close();
      } catch (_) {
        _log('[HEARTBEAT] worker lost');
        _safeRestart();
      }
    });
  }

  // ─────────────────────────────────────────────────────────────
  // INFERENCE (SAFE SERIALIZED)
  // ─────────────────────────────────────────────────────────────
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();

    () async {
      await _run(() async {
        if (_isInferenceActive) return;
        _isInferenceActive = true;

        final session = request.sessionId.trim().isEmpty
            ? 'default'
            : request.sessionId;

        if (!_activeSessions.add(session)) return;

        try {
          await _ensureWorker();

          final modelPath = request.modelPath!;
          final modelId = request.modelId!;

          // load model only if needed
          if (_loadedModelPath != modelPath) {
            final rp = ReceivePort();

            _sendPort!.send(
              _WorkerMessage(
                _WorkerCommand.loadModel,
                data: modelPath,
                replyPort: rp.sendPort,
              ),
            );

            final res = await rp.first;

            rp.close();

            if (res != 0) throw Exception('model load failed');

            _loadedModelPath = modelPath;
          }

          final prompt = LocalPromptTemplates.compose(
            modelId: modelId,
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            context: request.context,
          );

          final streamPort = ReceivePort();
          final startPort = ReceivePort();

          _sendPort!.send(
            _WorkerMessage(
              _WorkerCommand.startGeneration,
              data: {
                'prompt': prompt,
                'maxTokens': request.maxTokens.clamp(1, _safeMaxTokens),
                'temperature': request.temperature,
                'streamPort': streamPort.sendPort,
              },
              replyPort: startPort.sendPort,
            ),
          );

          if (await startPort.first != 0) {
            throw Exception('generation failed');
          }

          startPort.close();

          cancellationToken.onCancel(() {
            _sendPort?.send(_WorkerMessage(_WorkerCommand.cancel));
          });

          final buffer = <String>[];
          Timer? timer;

          void flush() {
            if (buffer.isEmpty || controller.isClosed) return;
            _emit(
              controller,
              InferenceResponse.token(
                text: buffer.join(),
                model: modelId,
              ),
            );
            buffer.clear();
          }

          await for (final e in streamPort) {
            if (controller.isClosed) break;
            if (e is! Map) continue;

            final type = e['type'];

            if (type == 'token') {
              buffer.add(e['text']);

              timer ??= Timer(const Duration(milliseconds: 20), flush);

              if (buffer.length >= 8) {
                timer?.cancel();
                flush();
              }
            }

            if (type == 'final') {
              timer?.cancel();
              flush();

              _emit(
                controller,
                InferenceResponse.finalChunk(
                  text: e['text'] ?? '',
                  tokensGenerated: e['tokens'] ?? 0,
                  model: modelId,
                ),
              );

              break;
            }

            if (type == 'error') {
              timer?.cancel();
              flush();

              _emit(
                controller,
                InferenceResponse.error(e['message'] ?? 'error'),
              );

              break;
            }
          }
        } catch (e) {
          _log('[ERROR] $e');

          _emit(controller, InferenceResponse.error(e.toString()));
        } finally {
          _isInferenceActive = false;
          _activeSessions.remove(session);

          await _memory().then(_policy);

          if (!controller.isClosed) {
            await controller.close();
          }
        }
      });
    }();

    return controller.stream;
  }

  Future<void> _run(Future<void> Function() fn) async {
    final prev = _queue;
    _queue = prev.then((_) => fn()).catchError((_) {});
    await _queue;
  }

  // ─────────────────────────────────────────────────────────────
  // WORKER ENTRY
  // ─────────────────────────────────────────────────────────────
  static void _entry(SendPort main) {
    final rp = ReceivePort();
    main.send(rp.sendPort);

    LlamaBridgeBindings? bindings;
    Pointer<Uint8>? buf;

    rp.listen((msg) async {
      if (msg is! _WorkerMessage) return;

      final reply = msg.replyPort;

      try {
        switch (msg.command) {
          case _WorkerCommand.loadModel:
            final lib = LlamaFfiLoader.tryLoadBridgeLibrary();
            bindings = lib?.bindings;
            reply?.send(bindings?.loadModel(msg.data) ?? -1);
            break;

          case _WorkerCommand.startGeneration:
            final d = msg.data as Map;
            final sp = d['streamPort'] as SendPort;

            buf ??= calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);

            final res = bindings?.startGeneration(
                  d['prompt'],
                  d['maxTokens'],
                  d['temperature'],
                ) ??
                -1;

            reply?.send(res);

            if (res == 0) {
              await _loop(bindings!, buf!, sp);
            }
            break;

          case _WorkerCommand.cancel:
            bindings?.cancel();
            reply?.send(true);
            break;

          case _WorkerCommand.freeModel:
            bindings?.freeModel();
            reply?.send(true);
            break;

          case _WorkerCommand.heartbeat:
            reply?.send(true);
            break;

          case _WorkerCommand.dispose:
            bindings?.freeModel();
            if (buf != null) calloc.free(buf!);
            rp.close();
            Isolate.exit();
        }
      } catch (_) {
        reply?.send(-1);
      }
    });
  }

  static Future<void> _loop(
    LlamaBridgeBindings b,
    Pointer<Uint8> buf,
    SendPort sp,
  ) async {
    final start = DateTime.now();
    int tokens = 0;

    while (true) {
      if (DateTime.now().difference(start) >
          const Duration(seconds: 90)) {
        sp.send({'type': 'error', 'message': 'timeout'});
        break;
      }

      final s = b.pollToken(buf);

      if (s == 1) {
        final text = buf.cast<Utf8>().toDartString();
        tokens++;
        sp.send({'type': 'token', 'text': text});
      } else if (s == 2) {
        sp.send({'type': 'final', 'tokens': tokens});
        break;
      } else {
        await Future.delayed(const Duration(milliseconds: 8));
      }
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _disposeWorker();
    super.dispose();
  }
}
