import 'package:ai_orchestrator/app/runtime_bootstrap.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockRuntimeEventLog extends Mock implements RuntimeEventLog {}

void main() {
  test('initializes runtime diagnostics persistence before emitting startup marker',
      () async {
    final runtimeEventLog = MockRuntimeEventLog();
    when(() => runtimeEventLog.initializePersistence())
        .thenAnswer((_) async {});
    when(
      () => runtimeEventLog.emit(
        '[FORENSIC_DIAGNOSTICS_PIPELINE_VERIFIED] startup',
      ),
    ).thenReturn(null);

    final bootstrap = RuntimeBootstrap(runtimeEventLog: runtimeEventLog);

    await bootstrap.initializeDiagnosticsPipeline();

    verifyInOrder([
      () => runtimeEventLog.initializePersistence(),
      () => runtimeEventLog.emit(
            '[FORENSIC_DIAGNOSTICS_PIPELINE_VERIFIED] startup',
          ),
    ]);
    verifyNoMoreInteractions(runtimeEventLog);
  });
}
