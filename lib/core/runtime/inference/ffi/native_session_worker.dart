import 'dart:ffi';
import 'dart:isolate';

import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:ffi/ffi.dart';

/// Loads a GGUF model and creates its native runtime session away from the
/// caller isolate.
///
/// `llb_create_session` performs synchronous llama.cpp model/context creation.
/// Running that call inside [Isolate.run] keeps Flutter's UI/runtime isolate
/// responsive while the native load is in progress. Only sendable primitive
/// values cross the isolate boundary; the native session registry itself is
/// process-global inside `libllama_bridge.so`.
///
/// Deliberately no Dart-side timeout is applied here. A Future timeout cannot
/// interrupt a synchronous FFI call and would only abandon a native load that
/// is still running. The caller therefore awaits the real native completion
/// and remains the owner of the returned session id.
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
