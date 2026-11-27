import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_reasoning_output.dart';

void main() {
  test('Qwen leading empty think block is suppressed at every split', () async {
    const raw = '<think>\n\n</think>\n\n17 × 24 = 408';
    for (var split = 0; split <= raw.length; split++) {
      final result = await AssistantReasoningOutput.answerAfterOptionalInitialReasoning(
        Stream.fromIterable([raw.substring(0, split), raw.substring(split)]),
      ).toList();
      expect(result.join(), '17 × 24 = 408', reason: 'split=$split');
    }
  });
  test('Qwen leading reasoning and split closing marker stay hidden', () async {
    final result = await AssistantReasoningOutput.answerAfterOptionalInitialReasoning(
      Stream.fromIterable(['<thi', 'nk>', List.filled(10000, 'x').join(), '</thi', 'nk>', '\n', 'OK']),
    ).toList();
    expect(result.join(), 'OK');
  });
  test('Qwen ordinary text, fenced code and inline literal tags stay intact', () async {
    for (final raw in ['Ciao!', ' \\n ordinary', 'Code: <think>example</think>',
        '```xml\n<think>literal</think>\n```']) {
      final result = await AssistantReasoningOutput.answerAfterOptionalInitialReasoning(
        Stream.fromIterable(raw.split('')),
      ).toList();
      expect(result.join(), raw);
    }
    expect(AssistantReasoningOutput.requestsLiteralThinkTags('Scrivi <think>'), isTrue);
    expect(AssistantReasoningOutput.requestsLiteralThinkTags('Scrivi &lt;/think&gt;'), isTrue);
    expect(AssistantReasoningOutput.requestsLiteralThinkTags('Quanto fa 17 × 24?'), isFalse);
  });
  test('Qwen reasoning without visible answer is incomplete', () async {
    for (final raw in ['<think>unfinished', '<think></think>   ']) {
      expect(AssistantReasoningOutput.answerAfterOptionalInitialReasoning(
        Stream.value(raw),
      ).toList(), throwsA(isA<AssistantReasoningIncomplete>()));
    }
  });

  test('pre-opened reasoning is not visible and final answer streams', () async {
    final result = await AssistantReasoningOutput.answerAfterInitialReasoning(
      Stream.fromIterable(['synthetic reasoning', '</think>', '4', '.'])).toList();
    expect(result.join(), '4.');
  });
  test('closing marker split at every boundary never leaks reasoning', () async {
    const marker = '</think>';
    for (var split = 1; split < marker.length; split++) {
      final result = await AssistantReasoningOutput.answerAfterInitialReasoning(
        Stream.fromIterable(['reason'+marker.substring(0, split),
          marker.substring(split)+'Answer'])).toList();
      expect(result.join(), 'Answer');
    }
  });
  test('long reasoning is discarded before bounded marker tail', () async {
    final result = await AssistantReasoningOutput.answerAfterInitialReasoning(
      Stream.fromIterable([List.filled(10000, 'x').join(), '</thi', 'nk>OK'])).toList();
    expect(result.join(), 'OK');
  });
  test('reasoning-only truncation is a distinct integration outcome', () async {
    expect(AssistantReasoningOutput.answerAfterInitialReasoning(
      Stream.fromIterable(['reasoning without a final answer'])).toList(),
      throwsA(isA<AssistantReasoningIncomplete>()));
  });
  test('closing marker without answer is incomplete', () async {
    expect(AssistantReasoningOutput.answerAfterInitialReasoning(
      Stream.fromIterable(['reason</think>   '])).toList(),
      throwsA(isA<AssistantReasoningIncomplete>()));
  });
}
