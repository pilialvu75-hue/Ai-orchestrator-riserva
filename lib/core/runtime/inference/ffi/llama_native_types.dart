import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef LlbInitBackendNative = Void Function();
typedef LlbInitBackendDart = void Function();

typedef LlbCreateSessionNative = Int64 Function(
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
);
typedef LlbCreateSessionDart = int Function(Pointer<Utf8>, int, int, int);

typedef LlbSessionStartGenNative = Int32 Function(Int64, Pointer<Utf8>, Int32, Float);
typedef LlbSessionStartGenDart = int Function(int, Pointer<Utf8>, int, double);

typedef LlbSessionPollTokenNative = Int32 Function(Int64, Pointer<Utf8>, Int32);
typedef LlbSessionPollTokenDart = int Function(int, Pointer<Utf8>, int);

typedef LlbSessionCancelNative = Void Function(Int64);
typedef LlbSessionCancelDart = void Function(int);

typedef LlbReleaseSessionNative = Void Function(Int64);
typedef LlbReleaseSessionDart = void Function(int);

typedef LlbSessionIsActiveNative = Int32 Function(Int64);
typedef LlbSessionIsActiveDart = int Function(int);

typedef LlbSessionLastErrorNative = Pointer<Utf8> Function(Int64);
typedef LlbSessionLastErrorDart = Pointer<Utf8> Function(int);

abstract final class LlamaNativeDefaults {
  // Conservative mobile runtime context for stable local generation.
  static const int nCtx = 2048;
  // Keep Android runtime thread usage bounded for thermals/stability.
  // This mirrors the native-side safe defaults used by llama_bridge.cpp.
  static const int nThreads = 2;
  // Intentionally high so runtimes can offload as many layers as the model/device allow.
  static const int nGpuLayers = 99;
  static const int nBatch = 32;
  static const double temperature = 0.7;
  static const int topK = 40;
  static const double topP = 0.9;
  static const int tokenBufferSize = 256;
}
