import 'package:ai_orchestrator/features/cloud_ai/data/models/ai_request_model.dart';
import 'package:ai_orchestrator/features/cloud_ai/domain/entities/ai_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiRequestModel', () {
    const tool = <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'search',
        'parameters': <String, dynamic>{'type': 'object'},
      },
    };

    const entity = AiRequest(
      prompt: 'Current question',
      systemPrompt: 'Base instructions',
      temperature: 0.4,
      maxTokens: 777,
      messages: <AiMessage>[
        AiMessage(role: AiMessageRole.system, content: 'Project rules'),
        AiMessage(role: AiMessageRole.user, content: 'Earlier question'),
        AiMessage(role: AiMessageRole.assistant, content: 'Earlier answer'),
      ],
      tools: <Map<String, dynamic>>[tool],
      modelId: 'custom-model',
      providerId: 'openAi',
      taskType: 'coding',
      metadata: <String, dynamic>{'executionId': 'exec-1'},
    );

    test('fromEntity copies structured fields instead of dropping them', () {
      final model = AiRequestModel.fromEntity(entity);

      expect(model.messages, entity.messages);
      expect(model.tools, entity.tools);
      expect(model.modelId, 'custom-model');
      expect(model.providerId, 'openAi');
      expect(model.taskType, 'coding');
      expect(model.metadata['executionId'], 'exec-1');
    });

    test('OpenAI payload keeps history ordered and appends current prompt', () {
      final model = AiRequestModel.fromEntity(entity);
      final json = model.toOpenAiJson();
      final messages = json['messages'] as List<dynamic>;

      expect(json['model'], 'custom-model');
      expect(json['tools'], entity.tools);
      expect(messages, hasLength(4));
      expect(messages[0], <String, String>{
        'role': 'system',
        'content': 'Base instructions\n\nProject rules',
      });
      expect(messages[1], <String, String>{
        'role': 'user',
        'content': 'Earlier question',
      });
      expect(messages[2], <String, String>{
        'role': 'assistant',
        'content': 'Earlier answer',
      });
      expect(messages[3], <String, String>{
        'role': 'user',
        'content': 'Current question',
      });
    });

    test('Gemini 3.8 payload maps assistant role and removes temperature', () {
      final model = AiRequestModel.fromEntity(entity);
      final json = model.toGeminiJson(model: 'gemini-3.8-flash');
      final contents = json['contents'] as List<dynamic>;
      final generationConfig = json['generationConfig'] as Map<String, dynamic>;

      expect(contents, hasLength(3));
      expect((contents[0] as Map<String, dynamic>)['role'], 'user');
      expect((contents[1] as Map<String, dynamic>)['role'], 'model');
      expect((contents[2] as Map<String, dynamic>)['role'], 'user');
      expect(generationConfig['maxOutputTokens'], 777);
      expect(generationConfig.containsKey('temperature'), isFalse);
      expect(json['systemInstruction'], isNotNull);
    });

    test('Claude payload keeps history and final user prompt', () {
      final model = AiRequestModel.fromEntity(entity);
      final messages = model.toClaudeMessages();

      expect(messages, <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Earlier question'},
        <String, String>{'role': 'assistant', 'content': 'Earlier answer'},
        <String, String>{'role': 'user', 'content': 'Current question'},
      ]);
      expect(model.combinedSystemPrompt, 'Base instructions\n\nProject rules');
    });
  });
}
