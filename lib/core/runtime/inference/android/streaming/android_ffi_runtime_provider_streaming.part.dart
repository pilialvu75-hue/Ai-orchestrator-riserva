part of runtime_core;

// ─────────────────────────────────────────────────────────────
// CONFIGURAZIONE STREAMING SAFE MODELS
// ─────────────────────────────────────────────────────────────
/// Set immutabile dei Model ID validati per l'esecuzione in streaming
/// ottimizzata su architettura Android FFI. Evita regressioni di memoria.
const Set<String> _androidSafeModelIds = <String>{
  LocalInferenceModelIds.llama1b,
  LocalInferenceModelIds.gemma2b,
  LocalInferenceModelIds.gemma2_2bIt,
  LocalInferenceModelIds.deepSeekR1_1_5b,
  LocalInferenceModelIds.qwen3_1_7b,
};

// ─────────────────────────────────────────────────────────────
// PARTS DISPATCHER (DIRETTIVE DI COMPILAZIONE)
// ─────────────────────────────────────────────────────────────
/// Separazione architetturale del runtime engine in blocchi logici isolati.
/// Condividono lo stato privato di [AndroidFfiRuntimeProvider] senza leak.

part 'android/streaming/android_ffi_runtime_provider_streaming.orchestrator.dart';
part 'android/streaming/android_ffi_runtime_provider_streaming.loop.dart';
