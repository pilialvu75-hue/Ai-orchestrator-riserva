import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const subsystemPath =
      'lib/core/runtime/inference/android/sessions/'
      'android_ffi_runtime_provider_native_session_subsystem.part.dart';

  String readSource() {
    final file = File(subsystemPath);
    expect(file.existsSync(), isTrue, reason: '$subsystemPath must exist');
    return file.readAsStringSync();
  }

  test('LRU model switch awaits graceful native-session shutdown', () {
    final source = readSource();

    expect(
      source,
      contains('Future<void> evictLeastRecentlyUsedSessionIfNeeded('),
    );
    expect(
      source,
      contains('await shutdownNativeSessionGracefully('),
      reason: 'The previous model must be cancelled and quiesced before release.',
    );
    expect(
      source,
      isNot(contains('bindings.releaseSession(evictedSessionId);')),
      reason: 'LRU eviction must never free a potentially generating session synchronously.',
    );
  });
}
