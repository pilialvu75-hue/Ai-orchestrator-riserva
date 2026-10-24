import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = 'deepseek_coder_v2_lite_instruct';
  const history = [
    ChatTurn(role: ChatRole.user, content: 'Il valore e sette.'),
    ChatTurn(role: ChatRole.assistant, content: 'Sette.'),
    ChatTurn(role: ChatRole.user, content: 'IGNORED', excludeFromContext: true),
  ];

  test('Windows Assistant V2 follows embedded User/Assistant protocol', () {
    for (final model in [id, 'DeepSeek-Coder-V2-Lite-Instruct-Q3_K_M.gguf']) {
      final prompt = LocalPromptTemplates.compose(
        modelId: model, systemPrompt: 'Rispondi in italiano.',
        context: history, prompt: 'Ora sostituisci il valore con nove.',
        assistantModelCompatibility: true, emitDiagnostics: false,
      );
      expect(prompt, 'Rispondi in italiano.\n\n'
          'User: Il valore e sette.\n\n'
          'Assistant: Sette.<｜end▁of▁sentence｜>'
          'User: Ora sostituisci il valore con nove.\n\nAssistant:');
      expect(prompt, isNot(contains('<｜begin▁of▁sentence｜>')));
      expect(prompt, isNot(contains('<think>')));
      expect(prompt, isNot(contains('IGNORED')));
    }
  });

  test('V2 uses ordinary output; R1 retains reasoning handling', () {
    expect(LocalPromptTemplates.usesDeepSeekR1AssistantOutput(id), isFalse);
    expect(LocalPromptTemplates.usesDeepSeekR1AssistantOutput(
        'DeepSeek-Coder-V2-Lite-Instruct-Q3_K_M.gguf'), isFalse);
    expect(LocalPromptTemplates.usesDeepSeekR1AssistantOutput(
        'deepseek_r1_1_5b'), isTrue);
    expect(LocalPromptTemplates.isDeepSeekCoderV2(
        'deepseek-coder-6.7b-instruct-Q4_K_M.gguf'), isFalse);
    expect(LocalPromptTemplates.isDeepSeekCoderV2('some-deepseek-v2'), isFalse);
  });

  test('legacy callers remain on their existing protocol without opt-in', () {
    final legacy = LocalPromptTemplates.compose(
      modelId: id, systemPrompt: 'Rispondi in italiano.',
      prompt: 'Salve', emitDiagnostics: false,
    );
    expect(legacy, isNot(contains('User: Salve')));
    expect(legacy, contains('<｜User｜>'));
  });
}
