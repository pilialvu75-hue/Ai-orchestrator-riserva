import 'package:ai_orchestrator/core/memory/assistant_durable_memory_context_service.dart';

import 'hybrid_cloud_disclosure_consent.dart';

/// Cloud disclosure adapter for *confirmed-only* memory data.
///
/// The app-owned header can be presented as an instruction, but every stored
/// memory record stays durableMemory/unknown until classification is verified.
/// It cannot silently obtain an automatic grant because unknown is never an
/// allowed persistent automatic disclosure category.
final class HybridCloudConfirmedMemoryProvenance {
  const HybridCloudConfirmedMemoryProvenance._();

  static List<HybridDisclosureSegment> toDisclosureSegments({
    required AssistantConfirmedMemoryContext source,
    required String exactContext,
  }) {
    if (source.text != exactContext || source.parts.isEmpty) {
      throw StateError('Memory disclosure differs from confirmed source');
    }
    final segments = List<HybridDisclosureSegment>.unmodifiable(
      source.parts.map((item) => HybridDisclosureSegment(
        text: item.text,
        scope: switch (item.kind) {
          AssistantMemoryContextPartKind.applicationHeader =>
            const HybridDisclosureScope(
              HybridDisclosureOrigin.systemInstructions,
              HybridDisclosureSensitivity.publicOrNonPersonal,
            ),
          AssistantMemoryContextPartKind.confirmedRecord =>
            const HybridDisclosureScope(
              HybridDisclosureOrigin.durableMemory,
              HybridDisclosureSensitivity.unknown,
            ),
        },
      )),
    );
    if (segments.map((part) => part.text).join() != exactContext ||
        !segments.any((part) =>
            part.scope.origin == HybridDisclosureOrigin.durableMemory)) {
      throw StateError('Missing confirmed memory disclosure evidence');
    }
    return segments;
  }
}
