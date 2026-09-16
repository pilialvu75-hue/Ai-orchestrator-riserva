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

typedef LlbSessionTokenCountNative = Int32 Function(Int64, Pointer<Utf8>);
typedef LlbSessionTokenCountDart = int Function(int, Pointer<Utf8>);

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
  // Keep a 4K logical context for assistant/code use. Native batching is
  // independently bounded, so long prompts are decoded in safe chunks rather
  // than submitted as one oversized llama_decode call.
  static const int nCtx = 4096;

  static final int _nThreads = _calculateThreadCount();

  static int _calculateThreadCount() {
    return threadCountForCores(Platform.numberOfProcessors);
  }

  static int threadCountForCores(int cores) {
    // Prefer performance cores without saturating every mobile CPU core. This
    // leaves headroom for Flutter, Android and the native streaming bridge.
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

  // Restore a deliberately conservative Vulkan split after the CPU baseline
  // isolated the native failures. Oversized prompt batches are now chunked by
  // the bridge and cancellation can interrupt decode. Ten layers gives LOCAL
  // prefill/generation meaningful acceleration while keeping most model
  // weights on CPU; session creation still falls back to CPU if Vulkan cannot
  // be initialized on the device.
  static const int nGpuLayers = 10;
}
