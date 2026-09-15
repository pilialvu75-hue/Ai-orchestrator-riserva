part of '../../runtime_core.dart';

class _AndroidFfiSessionStateIsolator {
  _AndroidFfiSessionStateIsolator();

  static const int _nativePromptSafetyMargin = 32;

  String composePrompt(
    InferenceRequest request, {
    required String modelId,
    bool bypassNonessentialLayers = false,
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

    String composeWithContext(List<NativeTokenBudgetTurn> context) {
      return LocalPromptTemplates.compose(
        modelId: modelId,
        prompt: request.prompt,
        systemPrompt: request.systemPrompt,
        context: context,
      );
    }

    final exactCounterAvailable =
        LlamaBridgeBindings.countTokensForCurrentSession('') != null;

    if (!exactCounterAvailable) {
      _log(
        '[CONTEXT_TOKEN_BUDGET] session=${request.sessionId} '
        'exact=false reason=no_active_native_counter '
        'context_turns=${request.context.length}',
      );
      return composeWithContext(request.context);
    }

    final requestedGenerationTokens = request.maxTokens > 0
        ? request.maxTokens
        : InferenceRequest.defaultMaxTokens;
    final generationHeadroom = requestedGenerationTokens
        .clamp(1, AndroidFfiRuntimeProvider._safeMaxTokens)
        .toInt();
    final maxPromptTokens =
        LlamaNativeDefaults.nCtx - generationHeadroom - _nativePromptSafetyMargin;

    int countExact(String prompt) {
      final count = LlamaBridgeBindings.countTokensForCurrentSession(prompt);
      if (count == null) {
        throw StateError(
          'Native token counter became unavailable during prompt budgeting.',
        );
      }
      return count;
    }

    final selection = NativeTokenContextBudget.select(
      context: request.context,
      composePrompt: composeWithContext,
      countTokens: countExact,
      maxPromptTokens: maxPromptTokens,
    );

    _log(
      '[CONTEXT_TOKEN_BUDGET] session=${request.sessionId} '
      'exact=true n_ctx=${LlamaNativeDefaults.nCtx} '
      'generation_headroom=$generationHeadroom '
      'safety_margin=$_nativePromptSafetyMargin '
      'max_prompt_tokens=$maxPromptTokens '
      'prompt_tokens=${selection.promptTokens} '
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
