import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_visual_attachment_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const image = ChatAttachment(id: 'image-1',
      type: ChatAttachmentType.image,
      path: '/synthetic/fixture.jpg', name: 'fixture.jpg');
  const video = ChatAttachment(id: 'video-1',
      type: ChatAttachmentType.video,
      path: '/synthetic/fixture.mp4', name: 'fixture.mp4');
  const file = ChatAttachment(id: 'file-1',
      type: ChatAttachmentType.file,
      path: '/synthetic/fixture.txt', name: 'fixture.txt');

  bool blocked(bool enabled, AiRuntimeMode? mode,
          Iterable<ChatAttachment> attachments) =>
      HybridCloudVisualAttachmentGuard.shouldDeny(
        consentGatedAssistantCloud: enabled,
        runtimeMode: mode,
        attachments: attachments,
      );

  test('opt-in Cloud denies image, video, and mixed visual requests', () {
    expect(blocked(true, AiRuntimeMode.cloud, const [image]), isTrue);
    expect(blocked(true, AiRuntimeMode.cloud, const [video]), isTrue);
    expect(blocked(true, AiRuntimeMode.cloud, const [file, image]), isTrue);
    expect(blocked(true, AiRuntimeMode.cloud, const [file, video]), isTrue);
  });

  test('text and classified document requests remain eligible for review', () {
    expect(blocked(true, AiRuntimeMode.cloud, const []), isFalse);
    expect(blocked(true, AiRuntimeMode.cloud, const [file]), isFalse);
  });

  test('on-device vision is unchanged in LOCAL and HYBRID', () {
    for (final mode in [AiRuntimeMode.local, AiRuntimeMode.hybrid]) {
      expect(blocked(true, mode, const [image]), isFalse);
      expect(blocked(true, mode, const [video]), isFalse);
    }
  });

  test('disabled feature preserves existing Cloud vision', () {
    expect(blocked(false, AiRuntimeMode.cloud, const [image]), isFalse);
    expect(blocked(false, AiRuntimeMode.cloud, const [video]), isFalse);
    expect(blocked(true, null, const [image]), isFalse);
  });
}
