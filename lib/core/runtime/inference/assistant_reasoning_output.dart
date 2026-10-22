/// Desktop Assistant raw DeepSeek prompts already open <think>.
/// Keep reasoning out of visible answer/timing without buffering its contents.
class AssistantReasoningIncomplete implements Exception {}

abstract final class AssistantReasoningOutput {
  static Stream<String> answerAfterInitialReasoning(Stream<String> source) async* {
    const closing = '</think>';
    var pending = '';
    var closed = false;
    var hasAnswer = false;
    await for (final chunk in source) {
      if (closed) {
        if (chunk.trim().isNotEmpty) hasAnswer = true;
        if (chunk.isNotEmpty) yield chunk;
        continue;
      }
      pending += chunk;
      final at = pending.indexOf(closing);
      if (at >= 0) {
        closed = true;
        final answer = pending.substring(at + closing.length);
        pending = '';
        if (answer.trim().isNotEmpty) hasAnswer = true;
        if (answer.isNotEmpty) yield answer;
      } else if (pending.length >= closing.length) {
        // Only a possible partial closing marker needs to survive the chunk.
        pending = pending.substring(pending.length - closing.length + 1);
      }
    }
    if (!closed || !hasAnswer) throw AssistantReasoningIncomplete();
  }
}
