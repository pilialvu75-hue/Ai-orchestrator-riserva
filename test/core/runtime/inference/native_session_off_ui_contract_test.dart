import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const workerPath =
      'lib/core/runtime/inference/ffi/native_session_worker.dart';
  const sessionSubsystemPath =
      'lib/core/runtime/inference/android/sessions/'
      'android_ffi_runtime_provider_native_session_subsystem.part.dart';
  const startupPath =
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_generation_startup.part.dart';
  const verificationPath =
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_stream_verification.part.dart';
  const warmupPath =
      'lib/core/runtime/inference/android/warmup/'
      'android_ffi_runtime_provider_warmup_subsystem.part.dart';
  const runtimeCorePath = 'lib/core/runtime/inference/runtime_core.dart';

  String readSource(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path must exist');
    return file.readAsStringSync();
  }

  group('native session off-UI contract', () {
    test('GGUF session creation runs inside a worker isolate', () {
      final source = readSource(workerPath);

      expect(source, contains('Future<int> createNativeSessionOffUi('));
      expect(source, contains('return Isolate.run(() {'));
      expect(source, contains("'llb_create_session'"));
      expect(
        source,
        isNot(contains('.timeout(')),
        reason: 'A Dart timeout cannot interrupt synchronous llb_create_session.',
      );
    });

    test('native session subsystem awaits worker creation for GPU and CPU', () {
      final source = readSource(sessionSubsystemPath);

      expect(source, contains('Future<int> ensureNativeSession('));
      expect(
        RegExp(r'await createNativeSessionOffUi\(')
            .allMatches(source)
            .length,
        2,
        reason: 'GPU creation and CPU fallback must both stay off the caller isolate',
      );
      expect(
        source,
        isNot(contains('bindings.createSession(modelPath')),
      );
    });

    test('production startup awaits real session completion without fake load timeout', () {
      final source = readSource(startupPath);

      expect(source, contains('nativeSessionId = await _ensureNativeSession('));
      expect(
        source,
        isNot(contains("stage: 'session_create',\n        timeout:")),
      );
      expect(source, contains('cancelled_after_session_create'));
    });

    test('isolated verification also creates its GGUF session off-UI', () {
      final source = readSource(verificationPath);

      expect(
        source,
        contains('final verificationSessionId = await createNativeSessionOffUi('),
      );
      expect(
        source,
        isNot(contains('bindings.createSession(modelPath)')),
      );
      expect(
        source,
        contains("reason: 'verification_scope_cleanup'"),
        reason: 'Verification must keep ownership of and release its isolated session.',
      );
    });

    test('warmup also awaits the same asynchronous session boundary', () {
      final source = readSource(warmupPath);

      expect(
        source,
        contains('await _owner._ensureNativeSession(bindings, modelPath)'),
      );
    });

    test('runtime core exposes asynchronous session acquisition only', () {
      final source = readSource(runtimeCorePath);

      expect(source, contains('Future<int> _ensureNativeSession('));
      expect(source, isNot(contains('_modelLoadTimeout')));
    });
  });
}
