part of '../../runtime_core.dart';

class _AndroidFfiSessionStateIsolator {
  _AndroidFfiSessionStateIsolator();

  String composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
    int Function(String prompt)? exactTokenCounter,
    int? requestedGenerationTokens,
  }) {
    if (bypassNonessentialLayers) {
      _log(
        '[FORENSIC_BYPASS] '
        'session=${request.sessionId} '
        'mode=raw_prompt_only '
        'semantic_memory=false '
        'embeddings=false '
        'workspace_indexing=false '
        'retrieval_augmentation=false '
        'conversation_rebuild=false',
      );
      return request.prompt.trim();
    }

    String composeWithContext(List<ChatTurn> context) {
      return LocalPromptTemplates.compose(
        modelId: modelId,
        prompt: request.prompt,
        systemPrompt: request.systemPrompt,
        context: context,
        applyLegacyContextBound: exactTokenCounter == null,
      );
    }

    if (exactTokenCounter == null || requestedGenerationTokens == null) {
      _log(
        '[CONTEXT_TOKEN_BUDGET] session=${request.sessionId} '
        'exact=false reason=no_explicit_native_counter '
        'context_turns=${request.context.length}',
      );
      return composeWithContext(request.context);
    }

    final selection = NativeTokenContextBudget.select(
      context: request.context,
      composePrompt: composeWithContext,
      countTokens: exactTokenCounter,
      nCtx: LlamaNativeDefaults.nCtx,
      requestedGenerationTokens: requestedGenerationTokens,
      safetyMargin: LlamaNativeDefaults.promptTokenSafetyMargin,
    );

    _log(
      '[CONTEXT_TOKEN_BUDGET] session=${request.sessionId} '
      'exact=true n_ctx=${LlamaNativeDefaults.nCtx} '
      'generation_headroom=$requestedGenerationTokens '
      'safety_margin=${LlamaNativeDefaults.promptTokenSafetyMargin} '
      'prompt_budget=${selection.promptBudgetTokens} '
      'prompt_tokens=${selection.promptTokens} '
      'available_generation=${selection.availableGenerationTokens} '
      'original_turns=${request.context.length} '
      'kept_turns=${selection.context.length} '
      'dropped_turns=${selection.droppedTurns} '
      'trimmed=${selection.wasTrimmed}',
    );

    return selection.prompt;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
