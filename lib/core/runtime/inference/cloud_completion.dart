enum CloudCompletionStatus {
  complete,
  incomplete,
  blocked,
  unknown,
}

/// Cloud-only completion metadata exposed by provider response adapters.
///
/// The shared [AiResponse] contract deliberately stays provider-neutral; Cloud
/// adapters implement this interface when their native API exposes a terminal
/// reason such as OpenAI `finish_reason`, Gemini `finishReason`, or Anthropic
/// `stop_reason`.
abstract interface class CloudCompletionAware {
  CloudCompletionStatus get completionStatus;
  String? get providerFinishReason;
  int? get inputTokens;
  int? get outputTokens;
  int? get reasoningTokens;
}

CloudCompletionStatus normalizeCloudCompletionReason(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return CloudCompletionStatus.unknown;
  final normalized = raw.toLowerCase().replaceAll('-', '_');

  switch (normalized) {
    case 'stop':
    case 'end_turn':
    case 'endturn':
    case 'stop_sequence':
      return CloudCompletionStatus.complete;
    case 'length':
    case 'max_tokens':
    case 'max_output_tokens':
    case 'max_tokens_reached':
      return CloudCompletionStatus.incomplete;
    case 'safety':
    case 'content_filter':
    case 'blocked':
    case 'recitation':
      return CloudCompletionStatus.blocked;
    default:
      return CloudCompletionStatus.unknown;
  }
}
