import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_bindings.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_ffi_loader.dart';
import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_state_machine.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

enum WorkerState { idle, loading, ready, generating, failed }

class _WorkerCommand {
  static const int loadModel = 0;
  static const int startGeneration = 1;
  static const int cancel = 2;
  static const int freeModel = 3;
  static const int dispose = 4;
  static const int heartbeat = 5;
}

class _WorkerMessage {
  final int command;
  final dynamic data;
  final SendPort? replyPort;

  _WorkerMessage(this.command, {this.data, this.replyPort});
}

class AndroidFfiRuntimeProvider extends LocalRuntimeProvider {
  AndroidFfiRuntimeProvider({
    RuntimeStateMachine? runtimeStateMachine,
  }) : super();

  static const _logTag = 'AI_RUNTIME_FFI';

  final RuntimeStateMachine runtimeStateMachine = RuntimeStateMachine();

  Isolate? _worker;
  SendPort? _sendPort;
  bool _workerReady = false;

  String? _loadedModelPath;

  final Set<String> _sessions = {};

  static void _log(String msg) {
    debugPrint('[$_logTag] $msg');
    RuntimeEventLog.instance.emit(msg);
  }

  // ───────────────────────────── WORKER LIFECYCLE ─────────────────────────────

  Future<void> _ensureWorker() async {
    if (_workerReady && _sendPort != null) return;

    final rp = ReceivePort();

    _worker = await Isolate.spawn(_entryPoint, rp.sendPort);

    _sendPort = await rp.first as SendPort;

    _workerReady = true;
    _log('Worker ready');
  }

  void _disposeWorker() {
    try {
      _sendPort?.send(_WorkerMessage(_WorkerCommand.dispose));
      _worker?.kill(priority: Isolate.immediate);
    } catch (_) {}

    _worker = null;
    _sendPort = null;
    _workerReady = false;
  }

  // ───────────────────────────── INFERENCE ─────────────────────────────

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    final controller = StreamController<InferenceResponse>();

    () async {
      try {
        await _ensureWorker();

        final modelPath = request.modelPath;
        if (modelPath == null) {
          controller.add(InferenceResponse.error("Missing model path"));
          controller.close();
          return;
        }

        if (_loadedModelPath != modelPath) {
          _log("Loading model $modelPath");
          _loadedModelPath = modelPath;

          _sendPort?.send(
            _WorkerMessage(
              _WorkerCommand.loadModel,
              data: modelPath,
            ),
          );
        }

        final rp = ReceivePort();

        _sendPort?.send(
          _WorkerMessage(
            _WorkerCommand.startGeneration,
            data: {
              "prompt": request.prompt,
              "maxTokens": 128,
              "temperature": 0.7,
              "streamPort": rp.sendPort,
            },
          ),
        );

        rp.listen((event) {
          if (event is Map) {
            final type = event["type"];

            if (type == "token") {
              controller.add(
                InferenceResponse.token(event["text"]),
              );
            } else if (type == "final") {
              controller.add(InferenceResponse.done());
              controller.close();
              rp.close();
            } else if (type == "error") {
              controller.add(InferenceResponse.error(event["message"]));
              controller.close();
              rp.close();
            }
          }
        });
      } catch (e) {
        controller.add(InferenceResponse.error(e.toString()));
        controller.close();
      }
    }();

    return controller.stream;
  }

  @override
  void dispose() {
    _disposeWorker();
    super.dispose();
  }

  // ───────────────────────────── WORKER ISOLATE ─────────────────────────────

  static void _entryPoint(SendPort mainPort) {
    final rp = ReceivePort();
    mainPort.send(rp.sendPort);

    LlamaBridgeBindings? bindings;
    Pointer<Uint8>? buf;

    rp.listen((msg) async {
      if (msg is! _WorkerMessage) return;

      try {
        switch (msg.command) {
          case _WorkerCommand.loadModel:
            final handle = LlamaFfiLoader.tryLoadBridgeLibrary();
            bindings = handle?.bindings;
            bindings?.loadModel(msg.data as String);
            msg.replyPort?.send(true);
            break;

          case _WorkerCommand.startGeneration:
            final data = msg.data as Map;

            final streamPort = data["streamPort"] as SendPort;

            buf ??= calloc<Uint8>(LlamaNativeDefaults.tokenBufferSize);

            final res = bindings?.startGeneration(
                  data["prompt"],
                  data["maxTokens"],
                  data["temperature"],
                ) ??
                -1;

            msg.replyPort?.send(res);

            if (res == 0) {
              await _loop(bindings!, buf!, streamPort);
            }
            break;

          case _WorkerCommand.cancel:
            bindings?.cancel();
            break;

          case _WorkerCommand.freeModel:
            bindings?.freeModel();
            break;

          case _WorkerCommand.dispose:
            bindings?.freeModel();
            if (buf != null) calloc.free(buf!);
            rp.close();
            Isolate.exit();
            break;

          case _WorkerCommand.heartbeat:
            msg.replyPort?.send(true);
            break;
        }
      } catch (_) {
        msg.replyPort?.send(false);
      }
    });
  }

  static Future<void> _loop(
    LlamaBridgeBindings bindings,
    Pointer<Uint8> buf,
    SendPort streamPort,
  ) async {
    int tokens = 0;
    final start = DateTime.now();

    while (true) {
      if (DateTime.now().difference(start).inSeconds > 90) {
        streamPort.send({"type": "error", "message": "timeout"});
        break;
      }

      final status = bindings.pollToken(buf);

      if (status == 1) {
        final text = buf.cast<Utf8>().toDartString();
        tokens++;
        streamPort.send({"type": "token", "text": text});
      } else if (status == 2) {
        streamPort.send({"type": "final", "tokens": tokens});
        break;
      } else {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
  }
}
