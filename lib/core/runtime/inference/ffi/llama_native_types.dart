import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef LlbInitBackendNative = Void Function();
typedef LlbInitBackendDart = void Function();

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
  // Conservative mobile runtime context for stable local generation.
  static const int nCtx = 2048;
  // Keep Android runtime thread usage bounded for thermals/stability while
  // still scaling up on higher-core devices.
  static final int _nThreads = _calculateThreadCount();

  static int _calculateThreadCount() {
    return threadCountForCores(Platform.numberOfProcessors);
  }

  static int threadCountForCores(int cores) {
    // Use 6 threads on octa-core devices to keep the decode loop responsive
    // without fully saturating the big.LITTLE cluster.
    if (cores >= 8) return 6;
    // Use 4 threads on mid-range devices so generation scales above the
    // previous hardcoded baseline while still leaving headroom for UI work.
    if (cores >= 6) return 4;
    // Fall back to 2 threads on smaller devices to avoid thermal spikes.
    return 2;
  }
  static int get nThreads => _nThreads;
  static int get nThreadsBatch => _nThreads;
  // Native prefill now sizes the batch to the active context instead of using
  // a fixed clamp, so the surfaced batch diagnostic mirrors n_ctx.
  static int get nBatch => LlamaNativeDefaults.nCtx;
  static const double temperature = 0.7;
  static const int topK = 40;
  static const double topP = 0.9;
  static const int tokenBufferSize = 256;
  // Number of model layers to request for GPU offload when Vulkan is available.
  // 99 exceeds the layer count of most GGUF models in use; llama.cpp clamps
  // any value above the actual layer count to that count, so passing 99 is
  // equivalent to "offload all layers". For future models with more than 99
  // layers, INT_MAX (-1 is treated as 0 by the bridge) would fully offload;
  // 99 is used here as a safe large-but-readable sentinel.
  // The C++ bridge clamps this to 0 at compile time when GGML_VULKAN is not
  // compiled in and logs a clear fallback message. If session creation with
  // GPU layers fails at runtime, the Dart layer retries with nGpuLayers=0.
  static const int nGpuLayers = 99;
}
