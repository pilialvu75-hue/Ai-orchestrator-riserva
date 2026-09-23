import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const runtimeCorePath =
      'lib/core/runtime/inference/runtime_core.dart';
  const pollingPath =
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_polling.part.dart';
  const verificationPath =
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_stream_verification.part.dart';

  test('production polling has one authoritative first-token deadline', () {
    final polling = File(pollingPath).readAsStringSync();

    expect(polling, contains('firstTokenDeadline'));
    expect(polling, contains('first_token_watchdog'));
    expect(polling, isNot(contains('_generationTimeout')));
    expect(polling, isNot(contains('generation_timeout_no_first_token')));
  });

  test('verification total timeout is isolated from production first token', () {
    final core = File(runtimeCorePath).readAsStringSync();
    final verification = File(verificationPath).readAsStringSync();

    expect(
      core,
      contains(
        'static const Duration _verificationTotalTimeout = '
        'Duration(seconds: 90);',
      ),
    );
    expect(
      core,
      contains(
        'static const Duration _stalledInferenceTimeoutRelease = '
        'Duration(seconds: 45);',
      ),
    );
    expect(
      core,
      contains(
        'static const Duration _stalledInferenceTimeoutDebug = '
        'Duration(seconds: 120);',
      ),
    );
    expect(verification, contains('_verificationTotalTimeout'));
    expect(verification, isNot(contains('_generationTimeout')));
  });

  test('post-first-token progress watchdog remains independent', () {
    final core = File(runtimeCorePath).readAsStringSync();
    final polling = File(pollingPath).readAsStringSync();

    expect(
      core,
      contains(
        'static const Duration _noTokenProgressTimeout = '
        'Duration(seconds: 35);',
      ),
    );
    expect(polling, contains('_noTokenProgressTimeout'));
    expect(polling, contains('token_progress_watchdog'));
  });
}
