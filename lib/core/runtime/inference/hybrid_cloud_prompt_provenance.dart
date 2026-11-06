import 'hybrid_cloud_disclosure_consent.dart';

/// Exact prompt slices created at the application-owned source boundary.
///
/// They are not classifications supplied by an LLM. Sensitivity of user
/// questions and document excerpts stays UNKNOWN until a separate trusted
/// classifier exists; therefore no blanket persistent auto-consent is possible.
enum HybridCloudPromptOrigin {
  userQuestion,
  appInstructions,
  documentExcerpt,
}

final class HybridCloudPromptPart {
  const HybridCloudPromptPart._(this.text, this.origin);

  final String text;
  final HybridCloudPromptOrigin origin;
}

/// An immutable, source-derived prompt representation.
///
/// The normal GGUF/Cloud prompt is exactly [prompt]. This contract alone does
/// not enable Cloud; it only transports trusted source boundaries to the
/// future consent-gated request assembler.
final class HybridCloudPromptProvenance {
  HybridCloudPromptProvenance._(List<HybridCloudPromptPart> sourceParts)
      : parts = List<HybridCloudPromptPart>.unmodifiable(sourceParts),
        prompt = sourceParts.map((part) => part.text).join();

  final List<HybridCloudPromptPart> parts;
  final String prompt;

  /// Called only from ChatFileContextService after local indexed excerpt
  /// retrieval. The file text never gets treated as an app instruction even
  /// if it embeds fake role headers or prompt delimiters.
  factory HybridCloudPromptProvenance.fromDocumentContext({
    required String originalQuestion,
    required String fallbackInstruction,
    required String beforeExcerpt,
    required String retrievedExcerpt,
    String afterExcerpt = '',
  }) {
    final question = originalQuestion.trim();
    if (retrievedExcerpt.isEmpty ||
        beforeExcerpt.isEmpty ||
        (question.isEmpty && fallbackInstruction.trim().isEmpty)) {
      throw ArgumentError('Incomplete locally indexed document provenance');
    }
    return HybridCloudPromptProvenance._(<HybridCloudPromptPart>[
      HybridCloudPromptPart._(
        question.isEmpty ? fallbackInstruction : question,
        question.isEmpty
            ? HybridCloudPromptOrigin.appInstructions
            : HybridCloudPromptOrigin.userQuestion,
      ),
      HybridCloudPromptPart._(
        beforeExcerpt, HybridCloudPromptOrigin.appInstructions,
      ),
      HybridCloudPromptPart._(
        retrievedExcerpt, HybridCloudPromptOrigin.documentExcerpt,
      ),
      if (afterExcerpt.isNotEmpty)
        HybridCloudPromptPart._(
          afterExcerpt, HybridCloudPromptOrigin.appInstructions,
        ),
    ]);
  }

  /// Refuses stale/edited prompts rather than attaching misleading labels.
  List<HybridDisclosureSegment> toDisclosureSegments({
    required String exactPrompt,
  }) {
    if (exactPrompt != prompt) {
      throw StateError('Cloud payload differs from source-derived provenance');
    }
    return List<HybridDisclosureSegment>.unmodifiable(
      parts.map((part) => HybridDisclosureSegment(
        text: part.text,
        scope: switch (part.origin) {
          HybridCloudPromptOrigin.userQuestion => const HybridDisclosureScope(
              HybridDisclosureOrigin.currentQuestion,
              HybridDisclosureSensitivity.unknown,
            ),
          HybridCloudPromptOrigin.appInstructions =>
            const HybridDisclosureScope(
              HybridDisclosureOrigin.systemInstructions,
              HybridDisclosureSensitivity.publicOrNonPersonal,
            ),
          HybridCloudPromptOrigin.documentExcerpt =>
            const HybridDisclosureScope(
              HybridDisclosureOrigin.documentExcerpt,
              HybridDisclosureSensitivity.unknown,
            ),
        },
      )),
    );
  }
}
