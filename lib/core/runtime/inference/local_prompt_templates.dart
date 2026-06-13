import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';

class LocalPromptTemplates {
  LocalPromptTemplates._();

  static String compose({
    required String modelId,
    required String prompt,
    String? systemPrompt,
    List<ChatTurn> context = const [],
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

    // Risolve il template per ID esatto O per pattern nome (modelli importati)
    final template = LocalInferenceModelIds.resolveTemplate(modelId);

    switch (template) {
      case 'llama3':
        return _buildLlama3Prompt(
          systemPrompt: cleanedSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      case 'qwen':
        return _buildQwenChatPrompt(
          systemPrompt: cleanedSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
          suppressThinking: LocalInferenceModelIds.isQwen3Thinking(modelId),
        );
      case 'gemma':
        return _buildGemmaPrompt(
          systemPrompt: cleanedSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      default:
        // Fallback generico: plain text
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
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Llama 3 Instruct chat template.
  ///
  /// Se l'ultimo turno del context ha role=user, viene tenuto separato
  /// dal nuovo userPrompt invece di essere fuso, per evitare duplicazioni
  /// quando il context window manager include già il messaggio corrente.
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
      buffer.write(
          '<|start_header_id|>${_roleName(turn.role)}<|end_header_id|>\n\n');
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
  /// Ogni turno del contesto viene emesso come blocco ChatML separato
  /// (<|im_start|>role ... <|im_end|>) invece di essere serializzato
  /// come testo grezzo dentro il blocco user. Questo impedisce al modello
  /// di vedere i tag ChatML come testo da ripetere nell'output.
  ///
  /// [suppressThinking] prepende /no_think al messaggio user per i modelli
  /// Qwen3 con chain-of-thought, evitando di sprecare il budget token su
  /// ragionamento interno prima della risposta finale.
  static String _buildQwenChatPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
    bool suppressThinking = false,
  }) {
    final buffer = StringBuffer();

    // System block
    buffer.write('<|im_start|>system\n');
    buffer.write(systemPrompt ?? 'You are a helpful assistant.');
    buffer.write('\n<|im_end|>\n');

    // Context turns — ognuno come blocco ChatML separato
    for (final turn in context) {
      buffer.write('<|im_start|>${_roleName(turn.role)}\n');
      buffer.write(turn.content);
      buffer.write('\n<|im_end|>\n');
    }

    // User turn corrente
    final effectiveUserPrompt =
        suppressThinking ? '/no_think\n$userPrompt' : userPrompt;
    buffer.write('<|im_start|>user\n');
    buffer.write(effectiveUserPrompt);
    buffer.write('\n<|im_end|>\n');

    // Apertura blocco assistant — il modello continua da qui
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
