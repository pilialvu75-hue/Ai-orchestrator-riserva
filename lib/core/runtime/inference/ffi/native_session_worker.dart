import 'dart:ffi';
import 'dart:isolate';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

/// Native session creation performs the synchronous GGUF model load inside
/// `llb_create_session`. Run that blocking FFI boundary on a worker isolate so
/// Flutter's calling isolate remains responsive while the model is loaded.
///
/// Only primitive values cross the isolate boundary. The native runtime keeps
/// its session registry process-wide, so the returned session id can be used by
/// the main runtime bindings after the worker returns.
Future<int> createNativeSessionOffUi(
  String modelPath, {
  required int nGpuLayers,
  int nCtx = LlamaNativeDefaults.nCtx,
  int? nThreads,
  String libraryPath = 'libllama_bridge.so',
}) {
  final effectiveThreads = nThreads ?? LlamaNativeDefaults.nThreads;
  return Isolate.run(() {
    final library = DynamicLibrary.open(libraryPath);
    final create = library.lookupFunction<
        LlbCreateSessionNative,
        LlbCreateSessionDart>('llb_create_session');
    final pathPtr = modelPath.toNativeUtf8(allocator: calloc);
    try {
      return create(
        pathPtr,
        nCtx,
        effectiveThreads,
        nGpuLayers,
      );
    } finally {
      calloc.free(pathPtr);
    }
  });
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
