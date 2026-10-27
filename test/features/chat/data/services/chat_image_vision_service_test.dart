import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/features/chat/data/services/chat_image_vision_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tmp;
  late File file;
  late ChatAttachment attachment;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('chat-vision-fixture-');
    file = File('${tmp.path}/image.png');
    await file.writeAsBytes(const <int>[
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      0, 0, 0, 0,
    ]);
    attachment = ChatAttachment(
      id: 'img1',
      type: ChatAttachmentType.image,
      path: file.path,
      name: 'image.png',
      mimeType: 'image/png',
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('OpenAI receives image pixels as data URL and returns visual answer',
      () async {
    var calls = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'mock-secret',
      modelFor: (_) => 'gpt-4o',
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/v1/chat/completions');
        expect(request.headers['authorization'], 'Bearer mock-secret');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['model'], 'gpt-4o');
        final messages = payload['messages'] as List<dynamic>;
        final current = messages.last as Map<String, dynamic>;
        final blocks = current['content'] as List<dynamic>;
        expect((blocks[0] as Map)['text'], 'Che cosa vedi?');
        final imageData = (blocks[1] as Map)['image_url'] as Map;
        expect((imageData['url'] as String), startsWith('data:image/png;base64,'));
        return http.Response(
          jsonEncode(<String, Object>{
            'model': 'gpt-4o',
            'choices': <Map<String, Object>>[
              <String, Object>{
                'message': <String, String>{'content': 'Un gatto sul divano.'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
    );
    final result = await service.analyze(
      providerId: 'openAi',
      prompt: 'Che cosa vedi?',
      image: attachment,
    );
    expect(result.providerId, 'openAi');
    expect(result.text, 'Un gatto sul divano.');
    expect(calls, 1);
  });

  test('Gemini receives inlineData and returns a real candidate text',
      () async {
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'gemini-secret',
      modelFor: (_) => 'gemini-3.8-flash',
      client: MockClient((request) async {
        expect(request.url.path, contains('gemini-3.8-flash:generateContent'));
        expect(request.headers['x-goog-api-key'], 'gemini-secret');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final parts =
            ((payload['contents'] as List).last as Map)['parts'] as List;
        expect((parts[0] as Map)['text'], contains('Descrivi questa immagine'));
        final inline = (parts[1] as Map)['inlineData'] as Map;
        expect(inline['mimeType'], 'image/png');
        expect(inline['data'], isNotEmpty);
        return http.Response(
          jsonEncode(<String, Object>{
            'modelVersion': 'gemini-3.8-flash',
            'candidates': <Map<String, Object>>[
              <String, Object>{
                'content': <String, Object>{
                  'parts': <Map<String, String>>[
                    <String, String>{'text': 'Vedo un edificio.'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          }),
          200,
        );
      }),
    );
    final result = await service.analyze(
      providerId: 'gemini',
      prompt: '',
      image: attachment,
    );
    expect(result.text, 'Vedo un edificio.');
  });

  test('Cloud AUTO picks configured Gemini without selecting paid OpenAI', () {
    final providers = <String>[];
    final selected = ChatImageVisionAutoRouter.select(
      manualProvider: null,
      automaticUseAllowed: (id) => id == 'gemini',
      hasCredential: (id) {
        providers.add(id);
        return id == 'gemini';
      },
    );
    expect(selected, 'gemini');
    expect(providers, <String>['gemini']);
  });

  test('Cloud AUTO does not bypass disabled free provider or missing key', () {
    expect(ChatImageVisionAutoRouter.select(
      manualProvider: null,
      automaticUseAllowed: (_) => false,
      hasCredential: (_) => true,
    ), isNull);
    expect(ChatImageVisionAutoRouter.select(
      manualProvider: null,
      automaticUseAllowed: (_) => true,
      hasCredential: (_) => false,
    ), isNull);
  });

  test('manual provider selection stays authoritative', () {
    expect(ChatImageVisionAutoRouter.select(
      manualProvider: 'openAi',
      automaticUseAllowed: (_) => false,
      hasCredential: (_) => false,
    ), 'openAi');
    expect(ChatImageVisionAutoRouter.select(
      manualProvider: 'nvidiaNim',
      automaticUseAllowed: (_) => true,
      hasCredential: (_) => true,
    ), isNull);
  });

  test('Gemini transient 503 retries once with identical image', () async {
    final bodies = <String>[];
    var attempts = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'gemini-secret',
      modelFor: (_) => 'gemini-3.8-flash',
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        attempts++;
        bodies.add(request.body);
        if (attempts == 1) return http.Response('overloaded', 503);
        return http.Response(jsonEncode(<String, Object>{
          'candidates': <Map<String, Object>>[
            <String, Object>{
              'content': <String, Object>{
                'parts': <Map<String, String>>[
                  <String, String>{'text': 'Vedo il logo.'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }), 200);
      }),
    );
    final response = await service.analyze(
      providerId: 'gemini',
      prompt: 'Cosa vedi?',
      image: attachment,
    );
    expect(response.text, 'Vedo il logo.');
    expect(attempts, 2);
    expect(bodies[0], bodies[1]);
  });

  test('Gemini repeated 503 stops after second request without secrets', () async {
    var attempts = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'private-gemini-secret',
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        attempts++;
        return http.Response('private server details', 503);
      }),
    );
    await expectLater(
      service.analyze(
        providerId: 'gemini',
        prompt: 'Cosa vedi?',
        image: attachment,
      ),
      throwsA(predicate((error) {
        final message = error.toString();
        return message.contains('503') &&
            !message.contains('private-gemini-secret') &&
            !message.contains('private server details');
      })),
    );
    expect(attempts, 2);
  });

  test('OpenAI paid request is never retried after 503', () async {
    var attempts = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'private-openai-secret',
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        attempts++;
        return http.Response('overloaded', 503);
      }),
    );
    await expectLater(
      service.analyze(providerId: 'openAi', prompt: '', image: attachment),
      throwsStateError,
    );
    expect(attempts, 1);
  });

  test('timeout fails clearly without repeating a request', () async {
    var attempts = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'gemini-secret',
      timeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
      client: MockClient((request) async {
        attempts++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('late', 200);
      }),
    );
    await expectLater(
      service.analyze(providerId: 'gemini', prompt: '', image: attachment),
      throwsA(predicate((error) => error.toString().contains('non ha risposto'))),
    );
    expect(attempts, 1);
  });

  test('never reroutes a photo to an unselected provider', () async {
    var calls = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'mock-secret',
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      service.analyze(
        providerId: 'nvidiaNim',
        prompt: 'Descrivi',
        image: attachment,
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('missing credential never uploads photo', () async {
    var calls = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => null,
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      service.analyze(
        providerId: 'gemini',
        prompt: 'Descrivi',
        image: attachment,
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('renamed nonimage content never leaves the device', () async {
    await file.writeAsString('This is not a picture');
    var calls = 0;
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'mock-secret',
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      service.analyze(
        providerId: 'openAi',
        prompt: 'Descrivi',
        image: attachment,
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('supports JPEG, PNG and WebP signatures only', () {
    expect(
      CloudChatImageVisionService.detectImageMime(<int>[0xFF, 0xD8, 0xFF]),
      'image/jpeg',
    );
    expect(
      CloudChatImageVisionService.detectImageMime(
        ascii.encode('RIFF0000WEBP'),
      ),
      'image/webp',
    );
    expect(CloudChatImageVisionService.detectImageMime(<int>[1, 2, 3]),
        isNull);
  });

  test('Cloud HTTP error is explicit and does not reveal secrets', () async {
    final service = CloudChatImageVisionService(
      credentialFor: (_) => 'do-not-leak',
      client: MockClient((request) async =>
          http.Response('forbidden: secret payload', 403)),
    );
    try {
      await service.analyze(
        providerId: 'gemini',
        prompt: 'Descrivi',
        image: attachment,
      );
      fail('Expected failure');
    } catch (error) {
      expect(error.toString(), contains('403'));
      expect(error.toString(), isNot(contains('do-not-leak')));
      expect(error.toString(), isNot(contains('secret payload')));
    }
  });
}
