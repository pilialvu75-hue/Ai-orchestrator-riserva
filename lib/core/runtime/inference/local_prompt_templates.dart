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
    
    // Filtro contestuale centralizzato per il RAG locale e la memoria
    final cleanedContext = context
        .where((turn) => !turn.excludeFromContext && turn.content.trim().isNotEmpty)
        .map((turn) => turn.copyWith(content: turn.content.trim()))
        .toList(growable: false);
        
    final userPrompt = prompt.trim();
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
      case 'phi3':
        return _buildPhi3Prompt(
          systemPrompt: cleanedSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      case 'zephyr':
        return _buildZephyrPrompt(
          systemPrompt: cleanedSystemPrompt,
          context: cleanedContext,
          userPrompt: userPrompt,
        );
      default:
        final buffer = StringBuffer();
        final isFactual = _isFactualQuery(userPrompt);
        buffer.writeln('<!--META temp=${isFactual ? 0.2 : 0.5} top_p=0.9 repeat_penalty=1.1 -->');
        
        if (cleanedSystemPrompt != null) {
          buffer.writeln('System: $cleanedSystemPrompt Respond in max 3 sentences. No speculation.');
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

  static bool _isFactualQuery(String prompt) {
    final p = prompt.toLowerCase();
    return p.contains('quanto') || 
           p.contains('quando') || 
           p.contains('chi è') || 
           p.contains('chi gioca') || 
           p.contains('dove') || 
           p.contains('cosè') || 
           p.contains('cosa è') || 
           p.contains('definizione') ||
           p.contains('colore') ||
           p.contains('cerca') ||
           p.contains('data') ||
           p.contains('anno');
  }

  /// Llama 3 Instruct — Configurato con metadati dinamici e blocchi eot
  static String _buildLlama3Prompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();
    final isFactual = _isFactualQuery(userPrompt);
    
    // FIX 1: Iniezione metadati sampling dinamico
    buffer.writeln('<!--META temp=${isFactual ? 0.2 : 0.5} top_p=0.9 repeat_penalty=1.1 -->');
    buffer.write('<|begin_of_text|>');
    buffer.write('<|start_header_id|>system<|end_header_id|>\n\n');
    
    final enforcedSystem = systemPrompt ?? 'You are a helpful, concise local assistant.';
    buffer.write('$enforcedSystem Respond in max 3 sentences. No speculation.');
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

  /// ChatML / Qwen — Controllo cicli e campionamento predittivo
  static String _buildQwenChatPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
    bool suppressThinking = false,
  }) {
    final buffer = StringBuffer();
    final isFactual = _isFactualQuery(userPrompt);
    
    // FIX 1: Iniezione metadati sampling dinamico
    buffer.writeln('<!--META temp=${isFactual ? 0.2 : 0.5} top_p=0.9 repeat_penalty=1.1 -->');
    buffer.write('<|im_start|>system\n');
    
    final enforcedSystem = systemPrompt ?? 'You are a helpful assistant.';
    buffer.write('$enforcedSystem Respond in max 3 sentences. No speculation.');
    buffer.write('\n<|im_end|>\n');
    
    for (final turn in context) {
      buffer.write('<|im_start|>${_roleName(turn.role)}\n');
      buffer.write(turn.content);
      buffer.write('\n<|im_end|>\n');
    }
    
    final effectiveUserPrompt = suppressThinking ? '/no_think\n$userPrompt' : userPrompt;
    buffer.write('<|im_start|>user\n');
    buffer.write(effectiveUserPrompt);
    buffer.write('\n<|im_end|>\n');
    buffer.write('<|im_start|>assistant\n');
    return buffer.toString();
  }

  /// Gemma chat template — Allineato con start_of_turn system nativo
  static String _buildGemmaPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();
    final isFactual = _isFactualQuery(userPrompt);
    
    // FIX 1: Iniezione metadati sampling dinamico
    buffer.writeln('<!--META temp=${isFactual ? 0.2 : 0.5} top_p=0.9 repeat_penalty=1.1 -->');
    
    final enforcedSystem = systemPrompt ?? 'You are a helpful assistant.';
    // FIX 2: Gemma usa <start_of_turn>system invece di user per il system prompt
    buffer.write('<start_of_turn>system\n$enforcedSystem Respond in max 3 sentences. No speculation.\n<end_of_turn>\n');
    
    for (final turn in context) {
      buffer.write('<start_of_turn>${_gemmaRoleName(turn.role)}\n');
      buffer.write('${turn.content}\n');
      buffer.write('<end_of_turn>\n');
    }
    buffer.write('<start_of_turn>user\n$userPrompt\n<end_of_turn>\n');
    buffer.write('<start_of_turn>model\n');
    return buffer.toString();
  }

  /// Phi-3 / Phi-3.5 chat template.
  static String _buildPhi3Prompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();

    final enforcedSystem = (systemPrompt ?? 'You are a helpful assistant.').trim();
    buffer.write('<|system|>\n$enforcedSystem\n<|end|>\n');

    for (final turn in context) {
      buffer.write('<|${_roleName(turn.role)}|>\n');
      buffer.write('${turn.content}\n');
      buffer.write('<|end|>\n');
    }

    buffer.write('<|user|>\n$userPrompt\n<|end|>\n');
    buffer.write('<|assistant|>\n');
    return buffer.toString();
  }

  /// Zephyr / TinyLlama template
  static String _buildZephyrPrompt({
    required String? systemPrompt,
    required List<ChatTurn> context,
    required String userPrompt,
  }) {
    final buffer = StringBuffer();
    final isFactual = _isFactualQuery(userPrompt);
    
    // FIX 1: Iniezione metadati sampling dinamico
    buffer.writeln('<!--META temp=${isFactual ? 0.2 : 0.5} top_p=0.9 repeat_penalty=1.1 -->');
    
    if (systemPrompt != null) {
      buffer.write('<|system|>\n$systemPrompt Respond in max 3 sentences. No speculation.\n</s>\n');
    } else {
      buffer.write('<|system|>\nYou are a helpful, concise local assistant. Respond in max 3 sentences. No speculation.\n</s>\n');
    }
    
    for (final turn in context) {
      final tag = _zephyrRoleName(turn.role);
      buffer.write('$tag\n${turn.content}\n</s>\n');
    }
    buffer.write('<|user|>\n$userPrompt\n</s>\n');
    buffer.write('<|assistant|>\n');
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
        return 'system';
      case ChatRole.user:
        return 'user';
    }
  }

  static String _zephyrRoleName(ChatRole role) {
    switch (role) {
      case ChatRole.assistant:
        return '<|assistant|>';
      case ChatRole.system:
        return '<|system|>';
      case ChatRole.user:
        return '<|user|>';
    }
  }
}
