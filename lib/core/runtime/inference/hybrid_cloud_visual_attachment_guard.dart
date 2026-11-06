import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';

/// Gated Assistant Cloud reviews text/document context, not binary vision.
/// Image and video use a separate legacy sender; forbid that unreviewed
/// destination only when the experimental consent transport is enabled.
abstract final class HybridCloudVisualAttachmentGuard {
  static bool shouldDeny({
    required bool consentGatedAssistantCloud,
    required AiRuntimeMode? runtimeMode,
    required Iterable<ChatAttachment> attachments,
  }) {
    if (!consentGatedAssistantCloud || runtimeMode != AiRuntimeMode.cloud) {
      return false;
    }
    return attachments.any((attachment) =>
        attachment.isImage || attachment.isVideo);
  }
}
