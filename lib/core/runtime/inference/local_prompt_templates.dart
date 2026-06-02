import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';

class LocalPromptTemplates {
  LocalPromptTemplates._();

  static String compose({
    required String modelId,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const <ChatTurn>[],
  }) {
    final cleanedSystemPrompt = _clean(systemPrompt);
    final cleanedContext = context
        .map((turn) => ChatTurn(
              role: turn.role,
              content: turn.content.trim(),
            ))
        .where((turn) => turn.content.isNotEmpty)
        .toList(growable: false);
    final userPrompt = prompt.trim();

    if (LocalInferenceModelIds.llama3ChatTemplateModels.contains(modelId)) {
      return _buildLlama3Prompt(
        systemPrompt: cleanedSystemPrompt,
        context: cleanedContext,
        userPrompt: userPrompt,
      );
    }
    if (LocalInferenceModelIds.qwenChatTemplateModels.contains(modelId)) {
      return _buildQwenChatPrompt(
        systemPrompt: cleanedSystemPrompt,
        context: cleanedContext,
        userPrompt: userPrompt,
        suppressThinking:
            LocalInferenceModelIds.qwen3ThinkingModels.contains(modelId),
      );
    }
    if (LocalInferenceModelIds.gemmaChatTemplateModels.contains(modelId)) {
      return _buildGemmaPrompt(
        systemPrompt: cleanedSystemPrompt,
        context: cleanedContext,
        userPrompt: userPrompt,
      );
    }

    final buffer = StringBuffer();
    if (cleanedSystemPrompt != null) {
      buffer.writeln('System: $cleanedSystemPrompt');
      buffer.writeln();
    }
    for (final turn in cleanedContext) {
      buffer.writeln('${_roleName(turn.role)}: ${turn.content}');
    }
    if (cleanedContext.isNotEmpty) buffer.writeln();
    buffer.write('User: $userPrompt');
    return buffer.toString();
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Llama 3 Instruct chat template.
  ///
  /// Required by all Meta Llama 3.x Instruct models (including Llama 3.2 1B
  /// Instruct).  The model is trained to stop at `<|eot_id|>` and expects
  /// the conversation structured with `<|start_header_id|>` role markers.
  /// Using the plain `User: …` fallback causes the model to misinterpret the
  /// prompt format, skip the EOS stop-sequence, and run through the full
  /// max-tokens budget without a meaningful answer.
  static String _buildLlama3Prompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();
    buffer.write('<|begin_of_text|>');
    buffer.write('<|start_header_id|>system<|end_header_id|>\n\n');
    buffer.write(systemPrompt ?? 'You are a helpful assistant.');
    buffer.write('<|eot_id|>');
    for (final turn in context) {
      buffer.write('<|start_header_id|>${_roleName(turn.role)}<|end_header_id|>\n\n');
      buffer.write(turn.content);
      buffer.write('<|eot_id|>');
    }
    buffer.write('<|start_header_id|>user<|end_header_id|>\n\n');
    buffer.write(userPrompt);
    buffer.write('<|eot_id|>');
    buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    return buffer.toString();
  }

  /// ChatML / Qwen chat template.
  ///
  /// [suppressThinking] prepends `/no_think` to the user message for Qwen3
  /// models.  Qwen3 enters a chain-of-thought "thinking" mode by default,
  /// emitting `<think>…</think>` tokens before the actual answer.  With the
  /// 128-token Android budget these thinking tokens consume the entire
  /// generation window, leaving nothing for the final response.  The `/no_think`
  /// directive instructs the model to skip the reasoning phase and reply
  /// directly — identical to setting `enable_thinking=False` in the Qwen3
  /// chat template.
  static String _buildQwenChatPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
    bool suppressThinking = false,
  }) {
    final contextualUserPrompt = context.isEmpty
        ? userPrompt
        : '${_serializeTurns(context)}\n$userPrompt';
    // Prepend /no_think for Qwen3 thinking models to avoid consuming all
    // available tokens on internal reasoning before the actual answer.
    final effectiveUserPrompt = suppressThinking
        ? '/no_think\n$contextualUserPrompt'
        : contextualUserPrompt;
    final buffer = StringBuffer();
    buffer.writeln('<|im_start|>system');
    buffer.writeln(systemPrompt ?? 'You are a helpful assistant.');
    buffer.writeln('<|im_end|>');
    buffer.writeln('<|im_start|>user');
    buffer.writeln(effectiveUserPrompt);
    buffer.writeln('<|im_end|>');
    buffer.write('<|im_start|>assistant\n');
    return buffer.toString();
  }

  static String _buildGemmaPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();
    if (systemPrompt != null) {
      buffer.write('<start_of_turn>user\n$systemPrompt\n<end_of_turn>\n');
    }
    for (final turn in context) {
      buffer.write('<start_of_turn>${_gemmaRoleName(turn.role)}\n');
      buffer.write('${turn.content}\n');
      buffer.write('<end_of_turn>\n');
    }
    buffer.write('<start_of_turn>user\n$userPrompt\n<end_of_turn>\n');
    buffer.write('<start_of_turn>model\n');
    return buffer.toString();
  }

  static String _serializeTurns(List<ChatTurn> turns) {
    return turns
        .map((turn) => '${_roleName(turn.role)}: ${turn.content}')
        .join('\n');
  }

  static String _roleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return 'assistant';
      case ChatRole.system:
        return 'system';
      case ChatRole.user:
        return 'user';
    }
  }

  static String _gemmaRoleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return 'model';
      case ChatRole.system:
        return 'user';
      case ChatRole.user:
        return 'user';
    }
  }
}
