import 'dart:ffi';
import 'dart:io';

import 'package:ai_orchestrator/core/runtime/inference/ffi/native_session_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native release waits off the caller isolate and is awaited to completion',
      () async {
    final dir = await Directory.systemTemp.createTemp('session-release-test-');
    final path = '${dir.path}/release_fixture.so';
    final build = await Process.run('cc', [
      '-shared', '-fPIC', '-std=gnu11',
      'test/fixtures/blocking_session_release.c', '-o', path,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
    final lib = DynamicLibrary.open(path);
    final phase = lib.lookupFunction<Int32 Function(), int Function()>(
        'release_phase');
    final allow = lib.lookupFunction<Void Function(), void Function()>(
        'allow_release');
    final release = releaseNativeSessionOffUi(42, libraryPath: path);
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (phase() == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // We can run Dart code while native release is waiting for permission.
      expect(phase(), 1);
    } finally {
      allow();
      await release;
      await dir.delete(recursive: true);
    }
    expect(phase(), 2);
  }, skip: !Platform.isLinux);
}
