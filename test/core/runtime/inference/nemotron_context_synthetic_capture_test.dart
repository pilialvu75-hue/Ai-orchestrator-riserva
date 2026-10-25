import 'dart:convert';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic data only. This exercises Dart composition, not the full UI/DB.
void main() {
  const system = 'Rispondi in italiano. Considera autorevole il valore piu recente fornito dall\'utente.';
  test('Dart Nemotron composition matches independently rendered native fixture', () {
    final actual = LocalPromptTemplates.compose(
      modelId: 'nemotron3_nano_4b',
      prompt: 'c vale 680',
      systemPrompt: system,
      context: const [
        ChatTurn(role: ChatRole.user, content: 'c vale 910'),
        ChatTurn(role: ChatRole.assistant, content: 'C=910'),
      ],
      enforceLegacyContextBound: false,
      emitDiagnostics: false,
    );
    // Independently captured from installed server /apply-template, 25 Oct.
    const nativeExpected = '<|im_start|>system\n'
        'Rispondi in italiano. Considera autorevole il valore piu recente fornito dall\'utente.<|im_end|>\n'
        '<|im_start|>user\nc vale 910<|im_end|>\n'
        '<|im_start|>assistant\n<think></think>C=910<|im_end|>\n'
        '<|im_start|>user\nc vale 680<|im_end|>\n'
        '<|im_start|>assistant\n<think></think>';
    expect(actual, nativeExpected);
    print('SYNTHETIC_DART_CONTEXT_CAPTURE ${jsonEncode({'fixture': 'assignment', 'prompt': actual})}');
  });

  test('explicit latest-value question follows both distinct user assignments', () {
    final actual = LocalPromptTemplates.compose(
      modelId: 'nemotron3_nano_4b',
      prompt: 'Qual è il valore più recente assegnato a c dall\'utente? Rispondi solo con il numero.',
      systemPrompt: system,
      context: const [
        ChatTurn(role: ChatRole.user, content: 'Assegna a c il valore 910.'),
        ChatTurn(role: ChatRole.assistant, content: 'C=910'),
        ChatTurn(role: ChatRole.user, content: 'Sostituisci il valore di c con 680.'),
        ChatTurn(role: ChatRole.assistant, content: 'C=680'),
      ],
      enforceLegacyContextBound: false,
      emitDiagnostics: false,
    );
    expect(actual.indexOf('Sostituisci il valore di c con 680.'), greaterThan(actual.indexOf('Assegna a c il valore 910.')));
    expect(actual.indexOf('Qual è il valore più recente'), greaterThan(actual.indexOf('Sostituisci il valore di c con 680.')));
    expect(actual, endsWith('<|im_start|>assistant\n<think></think>'));
    print('SYNTHETIC_DART_CONTEXT_CAPTURE ${jsonEncode({'fixture': 'explicit_recall', 'prompt': actual})}');
  });
}

