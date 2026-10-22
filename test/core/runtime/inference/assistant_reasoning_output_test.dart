import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/assistant_reasoning_output.dart';

void main() {
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
