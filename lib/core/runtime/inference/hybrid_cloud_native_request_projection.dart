import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';

/// Exact outgoing AiRequest projection for existing OpenAI and Gemini
/// native serializers only, after the real runtime has selected its provider.
///
/// Only explicitly known runtime trace metadata is removed, because neither
/// native serializer sends it. Unknown metadata and tools FAIL CLOSED.
/// This class never invents a source or sensitivity classification.
final class HybridCloudNativeRequestProjection {
  const HybridCloudNativeRequestProjection._();

  static const Set<String> _localTraceKeys = <String>{
    'sessionId', 'requestId', 'projectId', 'taskId',
    'executionId', 'attemptId', 'checkpointId',
  };

  static AiRequest project(AiRequest request) {
    if (request.providerId != 'openAi' &&
        request.providerId != 'gemini') {
      throw StateError('Unsupported consent-gated provider');
    }
    if (request.tools.isNotEmpty) {
      throw StateError('Unclassified Cloud tools');
    }
    for (final entry in request.metadata.entries) {
      if (!_localTraceKeys.contains(entry.key) ||
          entry.value is! String ||
          (entry.value as String).trim().isEmpty) {
        throw StateError('Unclassified Cloud metadata');
      }
    }
    // The actual adapter promotes legacy maxTokens 512 to 2048; show the
    // effective wire value, not the untransformed runtime value, in review.
    final converted = AiRequestModel.fromEntity(request);
    return AiRequest(
      prompt: request.prompt,
      systemPrompt: request.systemPrompt,
      temperature: converted.temperature,
      maxTokens: converted.maxTokens,
      messages: List<AiMessage>.unmodifiable(request.messages),
      modelId: converted.modelId,
      providerId: converted.providerId,
      taskType: converted.taskType,
      tools: const <Map<String, dynamic>>[],
      metadata: const <String, dynamic>{},
    );
  }
}
