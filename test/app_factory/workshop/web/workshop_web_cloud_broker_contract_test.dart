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
}
