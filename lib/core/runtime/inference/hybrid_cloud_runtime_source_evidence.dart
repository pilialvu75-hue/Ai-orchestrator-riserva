import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';

import 'hybrid_cloud_prompt_provenance.dart';

/// In-memory evidence from Chat's own input, not from an LLM-generated string.
///
/// The optional runtime suffix is only appended after the inference layer
/// proves that it created the exact extra system text (for example device
/// clock context). No data in this contract is written to telemetry/storage.
final class HybridCloudRuntimeSourceEvidence {
  HybridCloudRuntimeSourceEvidence({
    required this.sessionId,
    required this.originalQuestion,
    required this.baseSystemPrompt,
    required List<AiMessage> originalHistory,
    this.documentPrompt,
    this.confirmedMemory,
    this.runtimeSystemPromptSuffix = '',
  }) : originalHistory = List<AiMessage>.unmodifiable(
          originalHistory.map((message) => AiMessage(
            role: message.role, content: message.content,
          )),
        );

  final String sessionId;
  final String originalQuestion;
  final String baseSystemPrompt;
  final List<AiMessage> originalHistory;
  final HybridCloudPromptProvenance? documentPrompt;
  final AssistantConfirmedMemoryContext? confirmedMemory;
  final String runtimeSystemPromptSuffix;

  String get expectedSystemPrompt => <String>[
    if (baseSystemPrompt.trim().isNotEmpty) baseSystemPrompt.trim(),
    if (confirmedMemory?.text.isNotEmpty ?? false) confirmedMemory!.text,
    if (runtimeSystemPromptSuffix.isNotEmpty) runtimeSystemPromptSuffix,
  ].join('\n\n');

  /// Only the first-party InferenceService should call this with the exact
  /// time-context string it just added. This is not a general-purpose API for
  /// classifying arbitrary web/tool output as a system instruction.
  HybridCloudRuntimeSourceEvidence withTrustedRuntimeSystemAppend({
    required String previousSystemPrompt,
    required String appendedSystemPrompt,
    required String trustedSuffix,
  }) {
    if (trustedSuffix.trim().isEmpty ||
        previousSystemPrompt != expectedSystemPrompt ||
        appendedSystemPrompt != <String>[
          if (previousSystemPrompt.isNotEmpty) previousSystemPrompt,
          trustedSuffix,
        ].join('\n\n')) {
      throw StateError('Cloud runtime prompt changed outside trusted append');
    }
    return HybridCloudRuntimeSourceEvidence(
      sessionId: sessionId,
      originalQuestion: originalQuestion,
      baseSystemPrompt: baseSystemPrompt,
      originalHistory: originalHistory,
      documentPrompt: documentPrompt,
      confirmedMemory: confirmedMemory,
      runtimeSystemPromptSuffix: <String>[
        if (runtimeSystemPromptSuffix.isNotEmpty) runtimeSystemPromptSuffix,
        trustedSuffix,
      ].join('\n\n'),
    );
  }
}
