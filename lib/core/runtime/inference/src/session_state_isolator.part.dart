part of '../android_ffi_runtime_provider.dart';

class _AndroidFfiSessionStateIsolator {
  _AndroidFfiSessionStateIsolator(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  String composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
  }) {
    if (bypassNonessentialLayers) {
      _log(
        '[FORENSIC_BYPASS] session=${request.sessionId} mode=raw_prompt_only semantic_memory=false embeddings=false workspace_indexing=false retrieval_augmentation=false conversation_rebuild=false',
      );
      return request.prompt.trim();
    }
    return LocalPromptTemplates.compose(
      modelId: modelId,
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      context: request.context,
    );
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
