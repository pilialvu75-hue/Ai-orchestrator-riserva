import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic Cloud spending fails closed before settings are bound', () {
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isFalse,
    );
  });

  test('bound spending policy becomes authoritative at request time', () {
    var allow = false;
    CloudRuntimePreferences.instance.bind(
      preferredProvider: () => 'openAi',
      modelForProvider: (_) => 'model-1',
      automaticUseAllowed: (_) => allow,
    );

    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isFalse,
    );

    allow = true;

    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isTrue,
    );
  });
}
