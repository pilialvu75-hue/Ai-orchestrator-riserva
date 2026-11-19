import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_inference_model_ids.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_aivexus_local_decision_model.dart';

void main() {
  test('official MiniCPM5 Q4_K_M is available only as opt-in Windows candidate',
      () async {
    final decoded =
        jsonDecode(await File('assets/models/manifest.json').readAsString())
            as Map<String, dynamic>;
    final model = decoded['minicpm5_2b'] as Map<String, dynamic>;
    expect(model['fileName'], 'MiniCPM5-2B-Q4_K_M.gguf');
    expect(
      model['downloadUrl'],
      'https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/resolve/main/'
      'MiniCPM5-2B-Q4_K_M.gguf',
    );
    expect(model['sizeBytes'], 1560000000);
    expect(model['platformTarget'], 'windows');
    expect(decoded.containsKey('qwen2_5_3b_instruct'), isTrue);
  });

  test('MiniCPM5 model ID and imported filename use ChatML not plain transcript',
      () {
    for (final id in ['minicpm5_2b', 'MiniCPM5-2B-Q4_K_M.gguf']) {
      expect(
        LocalInferenceModelIds.resolveTemplate(id),
        LocalInferenceModelIds.templateMiniCpm5,
      );
      final prompt = LocalPromptTemplates.compose(
        modelId: id,
        systemPrompt: 'Rispondi in italiano.',
        prompt: 'Ciao',
        emitDiagnostics: false,
      );
      expect(prompt, contains('<|im_start|>system\n'));
      expect(prompt, contains('<|im_start|>user\nCiao'));
      expect(prompt, contains('<|im_start|>assistant\n'));
      expect(prompt, isNot(contains('/no_think')));
      expect(prompt, isNot(contains('<|start_header_id|>')));
    }
  });

  test('Computer Use only strips completed MiniCPM5 reasoning prefix', () {
    const response = '<think>Evaluation complete.</think>\n'
        '{"status":"act","action":"press_key","arguments":{"key":"left"}}';
    expect(
      AivexusComputerUseLocalDecisionModel.normalizePlannerText(
        'minicpm5_2b', response),
      '{"status":"act","action":"press_key","arguments":{"key":"left"}}',
    );
    expect(
      AivexusComputerUseLocalDecisionModel.normalizePlannerText(
        'qwen2_5_3b_instruct', response),
      response,
    );
    expect(
      AivexusComputerUseLocalDecisionModel.normalizePlannerText(
        'minicpm5_2b', '<think>unfinished'),
      '<think>unfinished',
    );
  });
}
