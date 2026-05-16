import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef LlbLoadModelNative = Int32 Function(Pointer<Utf8>, Int32, Int32);
typedef LlbLoadModelDart = int Function(Pointer<Utf8>, int, int);

typedef LlbStartGenNative = Int32 Function(Pointer<Utf8>, Int32, Float);
typedef LlbStartGenDart = int Function(Pointer<Utf8>, int, double);

typedef LlbPollTokenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef LlbPollTokenDart = int Function(Pointer<Utf8>, int);

typedef LlbCancelNative = Void Function();
typedef LlbCancelDart = void Function();

typedef LlbFreeModelNative = Void Function();
typedef LlbFreeModelDart = void Function();

typedef LlbLastErrorNative = Pointer<Utf8> Function();
typedef LlbLastErrorDart = Pointer<Utf8> Function();

typedef LlbIsLoadedNative = Int32 Function();
typedef LlbIsLoadedDart = int Function();

abstract final class LlamaNativeDefaults {
  // Conservative mobile runtime context for stable local generation.
  static const int nCtx = 2048;
  // Keep Android runtime thread usage bounded for thermals/stability.
  // This mirrors the native-side safe defaults used by llama_bridge.cpp.
  static const int nThreads = 2;
  static const int nBatch = 32;
  static const double temperature = 0.7;
  static const int topK = 40;
  static const double topP = 0.9;
  static const int tokenBufferSize = 256;
}
