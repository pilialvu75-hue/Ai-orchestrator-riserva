import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';

class AndroidFfiRuntimeModelIds {
  static const Set<String> validatedModelIds = <String>{
    LocalInferenceModelIds.llama1b,
    LocalInferenceModelIds.gemma2b,
    LocalInferenceModelIds.gemma2_2bIt,
    LocalInferenceModelIds.deepSeekR1_1_5b,
    LocalInferenceModelIds.qwen3_1_7b,
    LocalInferenceModelIds.phi3_5_mini,
  };
}
