import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef LlbInitBackendNative = Void Function();
typedef LlbInitBackendDart = void Function();

typedef LlbGpuBackendNameNative = Pointer<Utf8> Function();
typedef LlbGpuBackendNameDart = Pointer<Utf8> Function();

typedef LlbGpuBackendReasonNative = Pointer<Utf8> Function();
typedef LlbGpuBackendReasonDart = Pointer<Utf8> Function();

typedef LlbCreateSessionNative = Int64 Function(Pointer<Utf8>, Int32, Int32, Int32);
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
  // Contesto aumentato da 2048 a 4096: il tuo S24 FE (8/12GB RAM) regge
  // comodamente la KV cache aggiuntiva per modelli 7B in Q4_K_M, e un
  // contesto maggiore è essenziale per un uso da assistente di codice
  // (system prompt + contesto file + history nella stessa finestra).
  // Se noti pressione di memoria con modelli 7B, riporta a 2048 o 3072.
  static const int nCtx = 4096;

  static final int _nThreads = _calculateThreadCount();

  static int _calculateThreadCount() {
    return threadCountForCores(Platform.numberOfProcessors);
  }

  static int threadCountForCores(int cores) {
    // Snapdragon 8 Gen 3 (S24 FE) = 8 core: 1x Cortex-X4 + 5x Cortex-A720
    // + 2x Cortex-A520. Usiamo 6 thread per restare sui core performance
    // (X4+A720) senza saturare la cluster efficienza.
    if (cores >= 8) return 6;
    if (cores >= 6) return 4;
    return 2;
  }
  static int get nThreads => _nThreads;
  static int get nThreadsBatch => _nThreads;
  static const int nBatch = 512;
  static const double temperature = 0.7;
  static const int topK = 40;
  static const double topP = 0.9;
  static const int tokenBufferSize = 256;
  // Number of model layers to request for GPU offload when Vulkan is available.
  // 99 exceeds the layer count of most GGUF models in use; llama.cpp clamps
  // any value above the actual layer count to that count, so passing 99 is
  // equivalent to "offload all layers". The C++ bridge clamps this to 0 at
  // compile time when GGML_VULKAN is not compiled in (vedi fix CMakeLists.txt
  // per abilitare davvero il backend Vulkan) e logga un fallback chiaro.
  static const int nGpuLayers = 99;
}
