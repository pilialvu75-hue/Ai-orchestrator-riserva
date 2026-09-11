import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const controllerPath =
      'lib/core/runtime/inference/android/polling/'
      'android_ffi_runtime_provider_polling_controller.part.dart';

  test('idle poll count is diagnostic-only, never terminal', () {
    final file = File(controllerPath);
    expect(file.existsSync(), isTrue, reason: '$controllerPath must exist');

    final source = file.readAsStringSync();

    expect(source, contains('[POLL_IDLE_DIAGNOSTIC]'));
    expect(source, contains('terminal_authority=time_based_watchdogs'));
    expect(
      source,
      contains('bool isIdleLimitReached(int consecutiveIdlePolls)'),
    );
    expect(
      RegExp(
        r'bool isIdleLimitReached\(int consecutiveIdlePolls\)[\s\S]*?return false;',
      ).hasMatch(source),
      isTrue,
      reason:
          'A device-dependent poll count must not terminate local inference.',
    );
  });
}
