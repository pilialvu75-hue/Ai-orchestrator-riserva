import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('W4 server broker keeps provider selection and secrets server-side', () {
    final inference =
        File('functions/api/cantiere/inference.js').readAsStringSync();
    final capabilities =
        File('functions/api/cantiere/capabilities.js').readAsStringSync();

    for (final source in <String>[inference, capabilities]) {
      expect(source, contains('CANTIERE_CLOUD_ROUTES_JSON'));
      expect(source, contains("url.protocol !== 'https:'"));
      expect(source, contains('env[apiKeySecret]'));
    }

    expect(inference, contains("'architecture_reasoning'"));
    expect(inference, contains("'coding'"));
    expect(inference, contains("'review'"));
    expect(inference, contains("'orchestration'"));
    expect(inference, contains('MAX_MESSAGES = 32'));
    expect(inference, contains('MAX_TOTAL_CHARS = 60000'));
    expect(inference, contains('max_tokens: request.maxTokens'));
    expect(inference, contains('Authorization:'));
    expect(inference, contains(r'Bearer ${apiKey}'));

    // NVIDIA/OpenAI-compatible chat endpoints accept at most one optional
    // leading system message and then alternating user/assistant turns. Browser
    // history can add another system fragment, so the broker normalizes those
    // fragments into one leading system message before calling the provider.
    expect(inference, contains('const systemParts = []'));
    expect(inference, contains("if (row.role === 'system')"));
    expect(inference, contains("systemParts.join('\\n\\n')"));
    expect(inference, contains("messages.push({ role: 'system'"));
    expect(
      inference,
      contains('conversation[index - 1].role === conversation[index].role'),
    );

    // Free/hosted providers can transiently throttle or return 5xx. The broker
    // retries once server-side without exposing secrets or provider details to
    // the browser, then continues through the configured route fallbacks.
    expect(inference, contains('MAX_ROUTE_ATTEMPTS = 2'));
    expect(inference, contains('status === 429'));
    expect(inference, contains('status >= 500 && status <= 504'));
    expect(inference, contains("response.headers.get('retry-after')"));

    // When every route fails, only the bounded numeric upstream HTTP status is
    // surfaced. This makes a physical Web test distinguish auth/rate/model
    // failures without exposing the endpoint, model binding, key or body.
    expect(inference, contains('function upstreamError(status)'));
    expect(inference, contains('upstreamStatus'));
    expect(inference, contains('return upstreamError(lastFailureStatus)'));

    // No concrete provider endpoint, key or model is a browser/source default.
    expect(inference, isNot(contains('api.openai.com')));
    expect(inference, isNot(contains('openrouter.ai')));
    expect(inference, isNot(contains('integrate.api.nvidia.com')));
    expect(inference, isNot(contains('sk-')));
  });

  test('W4 broker exposes only bounded capability health', () {
    final capabilities =
        File('functions/api/cantiere/capabilities.js').readAsStringSync();

    expect(capabilities, contains("mode: 'auto'"));
    expect(capabilities, contains('capabilities: Object.keys(routes)'));
    expect(capabilities, isNot(contains('apiKey:')));
    expect(capabilities, isNot(contains('endpoint:')));
  });

  test('Web dictation requests microphone permission and exposes failures', () {
    final audio = File(
      'lib/app_factory/workshop/web/workshop_web_browser_audio_web.dart',
    ).readAsStringSync();

    expect(audio, contains('mediaDevices.getUserMedia'));
    expect(audio, contains('track.stop()'));
    expect(audio, contains("'not-allowed' || 'service-not-allowed'"));
    expect(audio, contains("'network'"));
    expect(audio, contains("'no-speech'"));
    expect(audio, contains('Controlli sito'));
  });
}
