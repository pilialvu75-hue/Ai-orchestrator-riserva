import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';

import 'hybrid_cloud_ai_request_seal.dart';
import 'hybrid_cloud_confirmed_memory_provenance.dart';
import 'hybrid_cloud_disclosure_consent.dart';
import 'hybrid_cloud_prompt_provenance.dart';

/// Trusted, provider-neutral assembler for the EXACT request selected by the
/// Cloud runtime. It never asks an LLM to classify its own input.
///
/// Current source coverage: user question, SQLite-confirmed memories, locally
/// indexed document/RAG excerpts and structured conversation history.
/// Web/tool results, binary attachments and unclassified extra system text
/// MUST NOT be passed off as another source: any mismatch fails closed.
///
/// This is a source-only integration API. Ordinary Chat does NOT invoke it yet.
final class HybridCloudTrustedRequestAssembler {
  const HybridCloudTrustedRequestAssembler._();

  static HybridCloudAiRequestSeal seal({
    required String ownerId,
    required String sessionId,
    required String accountId,
    required String purpose,
    required AiRequest request,
    required String originalQuestion,
    required String exactBaseSystemPrompt,
    required List<AiMessage> historySnapshot,
    HybridCloudPromptProvenance? documentPrompt,
    AssistantConfirmedMemoryContext? confirmedMemory,
  }) {
    final exactHistory = request.messages;
    if (historySnapshot.length != exactHistory.length ||
        request.tools.isNotEmpty ||
        request.metadata.isNotEmpty) {
      throw StateError('Unverified Cloud history, tools or metadata');
    }
    for (var i = 0; i < historySnapshot.length; i++) {
      if (historySnapshot[i].role != exactHistory[i].role ||
          historySnapshot[i].content != exactHistory[i].content) {
        throw StateError('Cloud history no longer matches trusted snapshot');
      }
    }

    final String expectedPrompt;
    final List<HybridDisclosureSegment> promptSegments;
    if (documentPrompt != null) {
      expectedPrompt = documentPrompt.prompt;
      // The user question embedded in the RAG request must still be the
      // original question, not user-like text from the retrieved document.
      final question = originalQuestion.trim();
      final actualQuestion = documentPrompt.parts.first;
      if (question.isNotEmpty &&
          (actualQuestion.origin != HybridCloudPromptOrigin.userQuestion ||
              actualQuestion.text != question)) {
        throw StateError('Document question differs from the user input');
      }
      if (question.isEmpty &&
          actualQuestion.origin != HybridCloudPromptOrigin.appInstructions) {
        throw StateError('Missing app-authored empty-question fallback');
      }
      promptSegments = documentPrompt.toDisclosureSegments(
        exactPrompt: request.prompt,
      );
    } else {
      expectedPrompt = originalQuestion.trim();
      if (expectedPrompt.isEmpty || expectedPrompt != request.prompt) {
        throw StateError('Cloud question differs from user input');
      }
      promptSegments = <HybridDisclosureSegment>[
        HybridDisclosureSegment(
          text: expectedPrompt,
          scope: const HybridDisclosureScope(
            HybridDisclosureOrigin.currentQuestion,
            HybridDisclosureSensitivity.unknown,
          ),
        ),
      ];
    }
    if (request.prompt != expectedPrompt) {
      throw StateError('Cloud prompt contains unverified additions');
    }

    // Base system text is application/config-owned, but might be customized
    // by a user or another tool. Until its origin is independently proven,
    // sensitivity remains UNKNOWN, forbidding permanent automatic approval.
    final base = exactBaseSystemPrompt.trim();
    final memoryText = confirmedMemory?.text;
    final expectedSystem = <String>[
      if (base.isNotEmpty) base,
      if (memoryText != null && memoryText.isNotEmpty) memoryText,
    ].join('\n\n');
    if ((request.systemPrompt ?? '') != expectedSystem) {
      throw StateError('Cloud system instructions contain unknown context');
    }
    final systemSegments = <HybridDisclosureSegment>[
      if (base.isNotEmpty)
        HybridDisclosureSegment(
          text: base,
          scope: const HybridDisclosureScope(
            HybridDisclosureOrigin.systemInstructions,
            HybridDisclosureSensitivity.unknown,
          ),
        ),
      if (base.isNotEmpty && memoryText != null && memoryText.isNotEmpty)
        const HybridDisclosureSegment(
          text: '\n\n',
          scope: HybridDisclosureScope(
            HybridDisclosureOrigin.systemInstructions,
            HybridDisclosureSensitivity.publicOrNonPersonal,
          ),
        ),
      if (confirmedMemory != null && memoryText != null &&
          memoryText.isNotEmpty)
        ...HybridCloudConfirmedMemoryProvenance.toDisclosureSegments(
          source: confirmedMemory,
          exactContext: memoryText,
        ),
    ];

    return HybridCloudAiRequestSeal.fromRequest(
      ownerId: ownerId,
      sessionId: sessionId,
      accountId: accountId,
      purpose: purpose,
      request: request,
      controlScope: const HybridDisclosureScope(
        HybridDisclosureOrigin.systemInstructions,
        HybridDisclosureSensitivity.publicOrNonPersonal,
      ),
      promptSegments: promptSegments,
      systemPromptSegments: systemSegments,
      historyScopes: <HybridDisclosureScope>[
        for (final _ in exactHistory)
          const HybridDisclosureScope(
            HybridDisclosureOrigin.conversationHistory,
            HybridDisclosureSensitivity.unknown,
          ),
      ],
    );
  }
}
