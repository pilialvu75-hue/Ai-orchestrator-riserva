import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/serial_inference_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waits for the preceding task before starting', () async {
    final previous = Completer<void>();
    var started = false;
    final task = runSerialInferenceTask(previous.future, () async {
      started = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    previous.complete();
    await task;
    expect(started, isTrue);
  });

  test('preserves task errors and permits the next request', () async {
    final error = StateError('generation failed');
    final failed = runSerialInferenceTask(Future<void>.value(), () async {
      throw error;
    });
    await expectLater(failed, throwsA(same(error)));
    var recovered = false;
    await runSerialInferenceTask(failed, () async {
      recovered = true;
    });
    expect(recovered, isTrue);
  });

  test('also reports synchronous action failures', () async {
    final error = StateError('startup failed');
    await expectLater(
      runSerialInferenceTask(Future<void>.value(), () => throw error),
      throwsA(same(error)),
    );
  });
}
