/// Desktop Assistant raw DeepSeek prompts already open <think>.
/// Keep reasoning out of visible answer/timing without buffering its contents.
class AssistantReasoningIncomplete implements Exception {}

abstract final class AssistantReasoningOutput {
  /// Only generated leading Qwen reasoning is a control sequence. Do not
  /// rewrite user text, code fences, or literal tags in ordinary answer text.
  static bool requestsLiteralThinkTags(String prompt) {
    final lower = prompt.toLowerCase();
    return lower.contains('<think>') || lower.contains('</think>') ||
        lower.contains('&lt;think&gt;') || lower.contains('&lt;/think&gt;');
  }

  /// Detect the optional opening marker across arbitrary transport chunks.
  /// Ordinary output passes through as soon as the prefix is disambiguated.
  /// A truncated reasoning block is an explicit incomplete answer, not a
  /// backend failure. Memory remains bounded while discarding reasoning.
  static Stream<String> answerAfterOptionalInitialReasoning(
    Stream<String> source,
  ) async* {
    const opening = '<think>';
    const closing = '</think>';
    var pending = '';
    var probing = true;
    var reasoning = false;
    var stripped = false;
    var hasAnswer = false;
    await for (final chunk in source) {
      if (probing) {
        pending += chunk;
        final candidate = pending.trimLeft();
        if (candidate.startsWith(opening)) {
          probing = false;
          reasoning = true;
          stripped = true;
          pending = candidate.substring(opening.length);
        } else if (pending.length <= 256 && opening.startsWith(candidate)) {
          continue;
        } else {
          probing = false;
          if (pending.isNotEmpty) yield pending;
          pending = '';
          continue;
        }
      } else {
        pending += chunk;
      }
      if (reasoning) {
        final end = pending.indexOf(closing);
        if (end < 0) {
          if (pending.length >= closing.length) {
            pending = pending.substring(pending.length - closing.length + 1);
          }
          continue;
        }
        reasoning = false;
        pending = pending.substring(end + closing.length);
      }
      if (stripped && !hasAnswer) {
        pending = pending.trimLeft();
        if (pending.isEmpty) continue;
        hasAnswer = true;
      }
      if (pending.isNotEmpty) yield pending;
      pending = '';
    }
    if (stripped && (reasoning || !hasAnswer)) {
      throw AssistantReasoningIncomplete();
    }
    if (probing && pending.isNotEmpty) yield pending;
  }

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
