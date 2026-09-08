import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const workerPath =
      'lib/core/runtime/inference/ffi/native_session_worker.dart';
  const startupPath =
      'lib/core/runtime/inference/android/streaming/'
      'android_ffi_runtime_provider_generation_startup.part.dart';
  const warmupPath =
      'lib/core/runtime/inference/android/warmup/'
      'android_ffi_runtime_provider_warmup_subsystem.part.dart';

  String load(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path must exist');
    return file.readAsStringSync();
  }

  group('native session model-load isolation contract', () {
    test('llb_create_session executes inside an Isolate.run worker', () {
      final worker = load(workerPath);

      expect(worker, contains('Future<int> createNativeSessionOffUi('));
      expect(worker, contains('return Isolate.run(() {'));
      expect(worker, contains("'llb_create_session'"));
      expect(worker, contains('DynamicLibrary.open(libraryPath)'));
    });

    test('production startup awaits off-ui session creation', () {
      final startup = load(startupPath);

      expect(
        startup,
        contains('nativeSessionId = await _ensureNativeSessionOffUi('),
      );
      expect(
        startup,
        isNot(contains(
          "stage: 'session_create', timeout: AndroidFfiRuntimeProvider._modelLoadTimeout",
        )),
      );
      expect(
        startup,
        contains('[NATIVE_SESSION_CREATE_OFF_UI_BEGIN]'),
      );
      expect(
        startup,
        contains('[NATIVE_SESSION_CREATE_OFF_UI_END]'),
      );
    });

    test('warmup uses the same off-ui session creation path', () {
      final warmup = load(warmupPath);

      expect(
        warmup,
        contains(
          'final warmupSessionId = await _owner._ensureNativeSessionOffUi(',
        ),
      );
      expect(
        warmup,
        isNot(contains(
          'final warmupSessionId = _owner._ensureNativeSession(bindings, modelPath);',
        )),
      );
    });

    test('model-load ownership waits for worker completion instead of timing out', () {
      final startup = load(startupPath);

      final helperStart = startup.indexOf(
        'Future<int> _ensureNativeSessionOffUi(',
      );
      final prepareStart = startup.indexOf(
        'Future<_GenerationStartupState?> _prepareGenerationStartup(',
      );
      expect(helperStart, greaterThanOrEqualTo(0));
      expect(prepareStart, greaterThan(helperStart));

      final helper = startup.substring(helperStart, prepareStart);
      expect(helper, contains('await createNativeSessionOffUi('));
      expect(helper, isNot(contains('.timeout(')));
      expect(helper, contains('_nativeSessionsByModel[modelPath]'));
      expect(helper, contains('effectiveGpuLayers = 0'));
    });
  });
}
