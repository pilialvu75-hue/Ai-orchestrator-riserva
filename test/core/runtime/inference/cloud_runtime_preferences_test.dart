import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_preferences.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_task_class.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic Cloud spending fails closed before settings are bound', () {
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isFalse,
    );
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowedForTask(
        'openAi',
        CloudTaskClass.coding,
      ),
      isFalse,
    );
  });

  test('legacy bound spending policy remains authoritative at request time', () {
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
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowedForTask(
        'openAi',
        CloudTaskClass.coding,
      ),
      isFalse,
    );

    allow = true;

    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isTrue,
    );
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowedForTask(
        'openAi',
        CloudTaskClass.reasoning,
      ),
      isTrue,
    );
  });

  test('task-aware policy does not leak complex authorization into general use',
      () {
    CloudRuntimePreferences.instance.bind(
      preferredProvider: () => 'openAi',
      modelForProvider: (_) => 'model-1',
      automaticUseAllowedForTask: (_, task) => task != CloudTaskClass.general,
    );

    expect(
      CloudRuntimePreferences.instance.automaticUseAllowed('openAi'),
      isFalse,
    );
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowedForTask(
        'openAi',
        CloudTaskClass.coding,
      ),
      isTrue,
    );
    expect(
      CloudRuntimePreferences.instance.automaticUseAllowedForTask(
        'openAi',
        CloudTaskClass.reasoning,
      ),
      isTrue,
    );
  });
}
