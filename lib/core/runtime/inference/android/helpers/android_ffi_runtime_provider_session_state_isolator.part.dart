part of runtime_core;

class _AndroidFfiSessionStateIsolator {
  _AndroidFfiSessionStateIsolator();

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
