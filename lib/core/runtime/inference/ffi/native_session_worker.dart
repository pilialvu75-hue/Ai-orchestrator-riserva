import 'dart:ffi';
import 'dart:isolate';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

class NativeSessionCreateResult {
  const NativeSessionCreateResult({
    required this.sessionId,
    required this.requestedGpuLayers,
    required this.effectiveGpuLayers,
    required this.firstAttemptResult,
  });

  final int sessionId;
  final int requestedGpuLayers;
  final int effectiveGpuLayers;
  final int firstAttemptResult;

  bool get usedCpuFallback =>
      requestedGpuLayers > 0 &&
      firstAttemptResult <= 0 &&
      effectiveGpuLayers == 0 &&
      sessionId > 0;
}

/// `llb_create_session` performs GGUF model/context loading synchronously.
/// Run that blocking native boundary on a worker isolate and return only
/// primitive result data to the caller isolate.
///
/// A GPU failure is retried with zero GPU layers inside the same worker so a
/// slow failed GPU load cannot return to the UI isolate only to block it again
/// during the CPU retry. This makes model loading responsive; it deliberately
/// does not claim to make `llama_model_load_from_file` cancellable.
Future<NativeSessionCreateResult> createNativeSessionOffUi(
  String modelPath, {
  int nGpuLayers = LlamaNativeDefaults.nGpuLayers,
  String libraryPath = 'libllama_bridge.so',
}) async {
  final requestedGpuLayers = nGpuLayers < 0 ? 0 : nGpuLayers;
  final rawResult = await Isolate.run<List<int>>(() {
    final library = DynamicLibrary.open(libraryPath);
    final create = library.lookupFunction<
        LlbCreateSessionNative,
        LlbCreateSessionDart>('llb_create_session');
    final pathPtr = modelPath.toNativeUtf8(allocator: calloc);

    try {
      final firstAttempt = create(
        pathPtr,
        LlamaNativeDefaults.nCtx,
        LlamaNativeDefaults.nThreads,
        requestedGpuLayers,
      );
      if (firstAttempt > 0 || requestedGpuLayers == 0) {
        return <int>[
          firstAttempt,
          requestedGpuLayers,
          firstAttempt,
        ];
      }

      final cpuAttempt = create(
        pathPtr,
        LlamaNativeDefaults.nCtx,
        LlamaNativeDefaults.nThreads,
        0,
      );
      return <int>[
        cpuAttempt,
        0,
        firstAttempt,
      ];
    } finally {
      calloc.free(pathPtr);
    }
  });

  return NativeSessionCreateResult(
    sessionId: rawResult[0],
    effectiveGpuLayers: rawResult[1],
    firstAttemptResult: rawResult[2],
    requestedGpuLayers: requestedGpuLayers,
  );
}

/// Native release joins the generation thread and can block until a decode
/// returns. Keep that wait off the UI isolate, while the caller still awaits
/// actual cleanup before reusing the runtime. Only send primitive values.
Future<void> releaseNativeSessionOffUi(
  int sessionId, {
  String libraryPath = 'libllama_bridge.so',
}) =>
    Isolate.run(() {
      final library = DynamicLibrary.open(libraryPath);
      final release = library.lookupFunction<Void Function(Int64),
          void Function(int)>('llb_release_session');
      release(sessionId);
    });
