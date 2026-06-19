import 'package:ai_orchestrator/features/onboarding/domain/entities/model_update_info.dart';

/// Provides model registry information.
/// In production this would query a remote JSON endpoint.
class ModelRegistryDataSource {
  const ModelRegistryDataSource();

  Future<List<ModelUpdateInfo>> getModelUpdates() async {
    // Simulate a brief network delay.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    return const [
      ModelUpdateInfo(
        modelId: 'gemma-3-4b',
        currentVersion: '3.0.0',
        latestVersion: '3.1.0',
        updateAvailable: true,
        downloadUrl: 'https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf',
      ),
      ModelUpdateInfo(
        modelId: 'phi3_5_mini',
        currentVersion: '3.8.0',
        latestVersion: '3.8.0',
        updateAvailable: false,
        downloadUrl:
            'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF',
      ),
      ModelUpdateInfo(
        modelId: 'llama-3-8b',
        currentVersion: '3.2.1',
        latestVersion: '3.3.0',
        updateAvailable: true,
        downloadUrl: 'https://huggingface.co/bartowski/Meta-Llama-3-8B-Instruct-GGUF',
      ),
    ];
  }
}
