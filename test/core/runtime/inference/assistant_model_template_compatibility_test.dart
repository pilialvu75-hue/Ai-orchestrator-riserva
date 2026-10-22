import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_prompt_templates.dart';

void main() {
  String compose(String id, {List<ChatTurn> history = const [],
      String system = 'Answer concisely.', String question = 'What is 2 + 2?',
      bool assistant = true}) => LocalPromptTemplates.compose(
        modelId: id, prompt: question, systemPrompt: system, context: history,
        assistantModelCompatibility: assistant, emitDiagnostics: false);

  test('Assistant Gemma matches native installed GGUF system folding fixture', () {
    expect(compose('gemma_2b_it'),
      '<start_of_turn>user\nAnswer concisely.\nWhat is 2 + 2?<end_of_turn>\n'
      '<start_of_turn>model\n');
    expect(compose('gemma_2b_it'), isNot(contains('<start_of_turn>system')));
    expect(compose('gemma_2b_it', assistant: false),
        contains('<start_of_turn>system'));
  });

  test('Gemma retains complete history and normalizes adjacent user turns', () {
    const history = [
      ChatTurn(role: ChatRole.user, content: 'Budget 750.'),
      ChatTurn(role: ChatRole.assistant, content: 'Received.'),
      ChatTurn(role: ChatRole.user, content: 'Correction: 920.'),
    ];
    final result = compose('gemma_2b_it', history: history, question: 'Budget?');
    expect(result, contains('<start_of_turn>model\nReceived.<end_of_turn>'));
    expect(result, contains('<start_of_turn>user\nCorrection: 920.\n\nBudget?<end_of_turn>'));
    expect(history[2].content, 'Correction: 920.');
  });

  test('Gemma retains an assistant-leading bounded history without invalid role order', () {
    final result = compose('gemma_2b_it', history: const [
      ChatTurn(role: ChatRole.assistant, content: 'Previous answer.'),
    ]);
    expect(result, startsWith('<start_of_turn>user\nAnswer concisely.<end_of_turn>'));
    expect(result, contains('<start_of_turn>model\nPrevious answer.<end_of_turn>'));
  });

  test('Assistant Spark matches native GGUF non-thinking generation fixture', () {
    const expected =
      '<｜start▁of▁sentence｜><|System|>\nyou are a helpful assistant.\n\nAnswer concisely.'
      '<｜end▁of▁sentence｜><｜start▁of▁sentence｜><|User|>What is 2 + 2?'
      '<｜end▁of▁sentence｜><｜start▁of▁sentence｜><|Bot|></think>';
    expect(compose('spark_x2_5_4b'), expected);
    expect(compose('Spark-X2.5-4B-Q4_K_M.gguf'), expected);
    expect(compose('spark_x2_5_4b', assistant: false), isNot(expected));
  });

  test('Spark omits completed historical reasoning but retains final answer and source URL', () {
    final result = compose('spark_x2_5_4b', history: const [
      ChatTurn(role: ChatRole.user, content: 'A fictional source?'),
      ChatTurn(role: ChatRole.assistant,
        content: '<think>private reasoning</think>Budget 420 https://example.test/a'),
    ], question: 'Which budget?');
    expect(result, isNot(contains('private reasoning')));
    expect(result, contains('<|Bot|></think>Budget 420 https://example.test/a'));
    expect(result, contains('<|User|>Which budget?'));
  });

  test('Other Assistant families remain unchanged by compatibility opt-in', () {
    for (final id in ['nemotron3_nano_4b', 'qwen3_1_7b',
        'phi3_5_mini', 'deepseek_r1_1_5b', 'llama-3.2-3b', 'llama_1b']) {
      expect(compose(id), compose(id, assistant: false));
    }
  });
}
