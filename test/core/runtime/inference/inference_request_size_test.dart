import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fractional mobile sizes do not match larger integer models', () {
    for (final id in ['qwen3-1.7b', 'deepseek-1.5b', 'model-1.8b']) {
      expect(InferenceRequest.maxTokensForModel(id), 512, reason: id);
      expect(InferenceRequest.temperatureForModel(id), 0.4, reason: id);
    }
    expect(InferenceRequest.maxTokensForModel('model-3.8b'), 768);
    expect(InferenceRequest.temperatureForModel('model-3.8b'), 0.5);
  });

  test('integer model sizes and Phi keep their intended profiles', () {
    expect(InferenceRequest.maxTokensForModel('model-7b-q4'), 1024);
    expect(InferenceRequest.maxTokensForModel('model_32b'), 3072);
    expect(InferenceRequest.maxTokensForModel('phi3_5_mini'), 1024);
    expect(InferenceRequest.maxTokensForModel('Phi-3.5-mini'), 1024);
    expect(InferenceRequest.maxTokensForModel(null), 512);
  });
}
