import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/kokoro_worker.dart';

void _fakeWorker(SendPort output) {
  final commands = ReceivePort();
  var count = 0;
  output.send(commands.sendPort);
  commands.listen((dynamic request) {
    if (request == null) {
      commands.close();
    } else {
      output.send(<String, Object?>{'count': ++count});
    }
  });
}

void main() {
  test('repeated generations share one owner and close rejects further work', () async {
    final worker = KokoroWorker(entryPoint: _fakeWorker);
    try {
      expect((await worker.generate({}))['count'], 1);
      expect((await worker.generate({}))['count'], 2);
      worker.close();
      await expectLater(worker.generate({}), throwsStateError);
    } finally {
      worker.close();
    }
  });
}
