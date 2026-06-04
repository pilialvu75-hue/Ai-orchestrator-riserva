part of runtime_core;

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURAZIONI E ECOSISTEMA DI CONFIGURAZIONE STREAMING LOCAL AI
// ─────────────────────────────────────────────────────────────────────────────

const Set<String> _androidSafeModelIds = <String>{
  LocalInferenceModelIds.llama1b,
  LocalInferenceModelIds.gemma2b,
  LocalInferenceModelIds.gemma2_2bIt,
  LocalInferenceModelIds.deepSeekR1_1_5b,
  LocalInferenceModelIds.qwen3_1_7b,
};

// Inclusione dei componenti atomici strutturali per mantenere i file sotto le 800 linee
part 'android_ffi_runtime_provider_streaming.orchestrator.dart';
part 'android_ffi_runtime_provider_streaming.loop.dart';
