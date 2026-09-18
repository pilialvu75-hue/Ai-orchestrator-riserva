import 'dart:math' as math;

import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

class NativeTokenContextSelection {
  const NativeTokenContextSelection({
    required this.context,
    required this.prompt,
    required this.promptTokens,
    required this.promptBudgetTokens,
    required this.availableGenerationTokens,
    required this.droppedTurns,
  });

  final List<ChatTurn> context;
  final String prompt;
  final int promptTokens;
  final int promptBudgetTokens;
  final int availableGenerationTokens;
  final int droppedTurns;

  bool get wasTrimmed => droppedTurns > 0;
  bool get fitsRequestedGeneration => promptTokens <= promptBudgetTokens;
}

/// Selects the largest coherent recent conversation suffix that fits the
/// native model context while preserving the requested generation headroom.
///
/// Capacity is measured exclusively with the caller-provided tokenizer. In
/// Android production that caller is the already-loaded llama.cpp RuntimeSession.
/// Individual messages are never truncated and the selected suffix always starts
/// on a user turn, so an assistant response is never injected without the user
/// turn it answers.
abstract final class NativeTokenContextBudget {
  static NativeTokenContextSelection select({
    required List<ChatTurn> context,
    required String Function(List<ChatTurn> context) composePrompt,
    required int Function(String prompt) countTokens,
    required int nCtx,
    required int requestedGenerationTokens,
    required int safetyMargin,
  }) {
    if (nCtx <= 0) {
      throw ArgumentError.value(nCtx, 'nCtx', 'must be > 0');
    }
    if (requestedGenerationTokens < 0) {
      throw ArgumentError.value(
        requestedGenerationTokens,
        'requestedGenerationTokens',
        'must be >= 0',
      );
    }
    if (safetyMargin < 0) {
      throw ArgumentError.value(
        safetyMargin,
        'safetyMargin',
        'must be >= 0',
      );
    }

    final normalized = context
        .where(
          (turn) =>
              !turn.excludeFromContext &&
              turn.role != ChatRole.system &&
              turn.content.trim().isNotEmpty,
        )
        .map((turn) => turn.copyWith(content: turn.content.trim()))
        .toList(growable: false);

    final promptBudgetTokens = math.max(
      0,
      nCtx - requestedGenerationTokens - safetyMargin,
    );
    final starts = _coherentStartIndexes(normalized);
    final cache = <int, NativeTokenContextSelection>{};

    NativeTokenContextSelection evaluate(int start) {
      final cached = cache[start];
      if (cached != null) return cached;

      final selected = start >= normalized.length
          ? const <ChatTurn>[]
          : List<ChatTurn>.unmodifiable(normalized.sublist(start));
      final prompt = composePrompt(selected);
      final promptTokens = countTokens(prompt);
      if (promptTokens < 0) {
        throw StateError('Tokenizer returned a negative prompt token count.');
      }

      final selection = NativeTokenContextSelection(
        context: selected,
        prompt: prompt,
        promptTokens: promptTokens,
        promptBudgetTokens: promptBudgetTokens,
        availableGenerationTokens: math.max(
          0,
          nCtx - promptTokens - safetyMargin,
        ),
        droppedTurns: normalized.length - selected.length,
      );
      cache[start] = selection;
      return selection;
    }

    // Keep the largest recent coherent suffix that fits. Prompt size decreases
    // monotonically as older complete turns are removed, so binary search avoids
    // repeatedly tokenizing every possible suffix.
    var low = 0;
    var high = starts.length - 1;
    NativeTokenContextSelection? best;

    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      final candidate = evaluate(starts[middle]);

      if (candidate.fitsRequestedGeneration) {
        best = candidate;
        high = middle - 1;
      } else {
        low = middle + 1;
      }
    }

    // If system + current user prompt alone cannot preserve all requested
    // generation headroom, return the empty-history candidate. The native #320
    // guard remains authoritative and can reduce generation capacity or fail if
    // the prompt itself exceeds nCtx.
    return best ?? evaluate(starts.last);
  }

  static List<int> _coherentStartIndexes(List<ChatTurn> context) {
    if (context.isEmpty) return const <int>[0];

    final starts = <int>[];
    for (var index = 0; index < context.length; index++) {
      if (context[index].role == ChatRole.user) {
        starts.add(index);
      }
    }

    // Context without a user turn is not conversationally coherent.
    if (starts.isEmpty) {
      return <int>[context.length];
    }

    // Empty history is always the final fallback.
    if (starts.last != context.length) {
      starts.add(context.length);
    }
    return starts;
  }
}
