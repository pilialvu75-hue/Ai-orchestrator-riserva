import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android startup selects and rechecks context with exact model tokens', () {
    final startup = File(
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_generation_startup.part.dart',
    ).readAsStringSync();

    expect(startup, contains('NativeTokenContextBudget.select('));
    expect(startup, contains('bindings.countTokens(nativeSessionId, candidatePrompt)'));
    expect(startup, contains('bindings.countTokens(nativeSessionId, prompt)'));
    expect(startup, contains('LlamaNativeDefaults.promptTokenSafetyMargin'));
    expect(startup, contains('[TOKEN_BUDGET_DART]'));
    expect(startup, contains('[TOKEN_BUDGET_DART_FINAL]'));
    expect(startup, contains('effectiveRequest.context.length'));
  });

  test('word count remains diagnostic, not the readiness authority', () {
    final startup = File(
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_generation_startup.part.dart',
    ).readAsStringSync();

    expect(startup, contains('promptWordEstimate'));
    expect(startup, contains('exactPromptTokens <= 0'));
    expect(
      startup,
      isNot(contains('if (promptWordEstimate <= 0)')),
    );
  });
}
