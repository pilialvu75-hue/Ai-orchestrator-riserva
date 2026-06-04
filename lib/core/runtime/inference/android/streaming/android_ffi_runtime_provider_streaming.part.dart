part of 'package:ai_orchestrator/core/runtime/inference/runtime_core.dart';

// ─────────────────────────────────────────────────────────────
// CONFIGURAZIONE STREAMING SAFE MODELS
// ─────────────────────────────────────────────────────────────

/// Set immutabile dei Model ID validati per l'esecuzione in streaming
/// ottimizzata su architettura Android FFI.
const Set<String> _androidSafeModelIds = <String>{
  LocalInferenceModelIds.llama1b,
  LocalInferenceModelIds.gemma2b,
  LocalInferenceModelIds.gemma2_2bIt,
  LocalInferenceModelIds.deepSeekR1_1_5b,
  LocalInferenceModelIds.qwen3_1_7b,
};

// ─────────────────────────────────────────────────────────────
// FFI IMPORT SAFETY (necessario per evitare errori cascading)
// ─────────────────────────────────────────────────────────────

import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ─────────────────────────────────────────────────────────────
// PARTS DISPATCHER
// ─────────────────────────────────────────────────────────────

/// Separazione architetturale del runtime engine in blocchi logici isolati.
/// Condividono lo stato privato del runtime core.
part 'android/streaming/android_ffi_runtime_provider_streaming.orchestrator.dart';
part 'android/streaming/android_ffi_runtime_provider_streaming.loop.dart';
