import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef LlbInitBackendNative = Void Function();
typedef LlbInitBackendDart = void Function();

typedef LlbGpuBackendNameNative = Pointer<Utf8> Function();
typedef LlbGpuBackendNameDart = Pointer<Utf8> Function();

typedef LlbGpuBackendReasonNative = Pointer<Utf8> Function();
typedef LlbGpuBackendReasonDart = Pointer<Utf8> Function();

typedef LlbCreateSessionNative = Int64 Function(
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
);
typedef LlbCreateSessionDart = int Function(Pointer<Utf8>, int, int, int);

typedef LlbCreateSessionExNative = Int64 Function(
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
  Int32,
  Int32,
);
typedef LlbCreateSessionExDart = int Function(
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
  int,
);

typedef LlbSessionTokenCountNative = Int32 Function(Int64, Pointer<Utf8>);
typedef LlbSessionTokenCountDart = int Function(int, Pointer<Utf8>);

typedef LlbSessionStartGenNative = Int32 Function(
  Int64,
  Pointer<Utf8>,
  Int32,
  Float,
);
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
  // Baseline capacity; session resource profiles may select a smaller context.
  // Prompt budgeting must read the effective native capacity.
  static const int nCtx = 4096;

  /// Must stay aligned with kPromptTokenSafetyMargin in the native bridge.
  static const int promptTokenSafetyMargin = 32;

  static final int _nThreads = _calculateThreadCount();

  static int _calculateThreadCount() {
    return threadCountForCores(Platform.numberOfProcessors);
  }

  static int threadCountForCores(int cores) {
    // Bound CPU concurrency without assuming a particular device chipset.
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
  // Intermediate physical A/B candidate derived from the validated Vulkan-10
  // source after Vulkan-50 reached full offload (33 effective layers), became
  // slower, and triggered critical-memory protection on the third prompt.
  // Keep the memory guard unchanged; validate repeated prompts on S24 FE.
  static const int nGpuLayers = 20;
}
