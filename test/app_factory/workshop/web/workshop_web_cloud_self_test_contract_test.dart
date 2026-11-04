import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Synthetic broker probe fails closed without an explicit free route', () {
    final source = File('functions/api/cantiere/inference.js').readAsStringSync();

    expect(source, contains("const SELF_TEST_MARKER = 'AIVEXUS_WEB_SELF_TEST_OK'"));
    expect(source, contains('selfTestFree: row.selfTestFree === true'));
    expect(source, contains("(route) => !selfTest || route.selfTestFree"));
    expect(source, contains("'self_test_not_configured'"));
    expect(source, contains("selfTest && capability !== 'orchestration'"));
    expect(source, contains("const messages = selfTest"));
    expect(source, contains("maxTokens: selfTest"));
    expect(source, contains("temperature: selfTest"));
    expect(source, contains("topP: selfTest"));
    expect(source, contains('reportedModel:'));
    expect(source, contains('provider: providerForEndpoint(route.endpoint)'));
  });

  test('Self-test UI stays in Web Status and never uses local inference', () {
    final shell = File('lib/app_factory/workshop/web/workshop_web_shell.dart')
        .readAsStringSync();
    final probe = File(
      'lib/app_factory/workshop/web/workshop_web_cloud_self_test.dart',
    ).readAsStringSync();

    expect(shell, contains('Esegui Self-Test Cloud'));
    expect(shell, contains('WorkshopWebCloudSelfTestClient'));
    expect(probe, contains("'selfTest': true"));
    expect(probe, contains("'capability': 'orchestration'"));
    expect(probe, isNot(contains('apiKey:')));
    expect(probe, isNot(contains('Authorization:')));
    expect(probe, isNot(contains('modelId:')));
  });
}
