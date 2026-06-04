part of runtime_core;

// ─────────────────────────────────────────────────────────────
// CONFIGURAZIONE STREAMING SAFE MODELS
// ─────────────────────────────────────────────────────────────

const Set<String> _androidSafeModelIds = <String>{
  LocalInferenceModelIds.llama1b,
  LocalInferenceModelIds.gemma2b,
  LocalInferenceModelIds.gemma2_2bIt,
  LocalInferenceModelIds.deepSeekR1_1_5b,
  LocalInferenceModelIds.qwen3_1_7b,
};

// ─────────────────────────────────────────────────────────────
// PARTS DISPATCHER
// ─────────────────────────────────────────────────────────────

part 'android/streaming/android_ffi_runtime_provider_streaming.orchestrator.dart';
part 'android/streaming/android_ffi_runtime_provider_streaming.loop.dart';
