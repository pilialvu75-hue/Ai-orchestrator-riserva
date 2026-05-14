import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';

void main() {
  group('LocalRuntimeState', () {
    test('default state is uninitialized with no message', () {
      const state = LocalRuntimeState();
      expect(state.status, LocalRuntimeStatus.uninitialized);
      expect(state.message, isNull);
    });

    test('copyWith updates status and message independently', () {
      const original = LocalRuntimeState(
        status: LocalRuntimeStatus.loading,
        message: 'loading…',
      );

      final updated = original.copyWith(status: LocalRuntimeStatus.ready);
      expect(updated.status, LocalRuntimeStatus.ready);
      // message is cleared when not supplied to copyWith
      expect(updated.message, isNull);

      final msgOnly = original.copyWith(message: 'new message');
      expect(msgOnly.status, LocalRuntimeStatus.loading);
      expect(msgOnly.message, 'new message');
    });

    test('equality compares status and message', () {
      const a = LocalRuntimeState(
          status: LocalRuntimeStatus.failed, message: 'oops');
      const b = LocalRuntimeState(
          status: LocalRuntimeStatus.failed, message: 'oops');
      const c = LocalRuntimeState(
          status: LocalRuntimeStatus.failed, message: 'other');

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('toString includes status name', () {
      const state =
          LocalRuntimeState(status: LocalRuntimeStatus.inferencing);
      expect(state.toString(), contains('inferencing'));
    });
  });

  group('LocalRuntimeMonitor', () {
    test('initial state is uninitialized', () {
      final monitor = LocalRuntimeMonitor();
      expect(monitor.state.status, LocalRuntimeStatus.uninitialized);
    });

    test('update transitions state and notifies listener', () {
      final monitor = LocalRuntimeMonitor();
      final received = <LocalRuntimeState>[];

      monitor.addListener(received.add);

      monitor.update(LocalRuntimeStatus.loading, message: 'loading model');

      expect(monitor.state.status, LocalRuntimeStatus.loading);
      expect(monitor.state.message, 'loading model');
      expect(received, hasLength(1));
      expect(received.first.status, LocalRuntimeStatus.loading);
    });

    test('multiple listeners all receive updates', () {
      final monitor = LocalRuntimeMonitor();
      var calls1 = 0;
      var calls2 = 0;

      monitor.addListener((_) => calls1++);
      monitor.addListener((_) => calls2++);

      monitor.update(LocalRuntimeStatus.ready);
      monitor.update(LocalRuntimeStatus.inferencing);

      expect(calls1, 2);
      expect(calls2, 2);
    });

    test('removeListener stops future notifications', () {
      final monitor = LocalRuntimeMonitor();
      var calls = 0;
      void listener(LocalRuntimeState _) => calls++;

      monitor.addListener(listener);
      monitor.update(LocalRuntimeStatus.loading);
      expect(calls, 1);

      monitor.removeListener(listener);
      monitor.update(LocalRuntimeStatus.ready);
      expect(calls, 1); // no further calls
    });

    test('update without message leaves message null', () {
      final monitor = LocalRuntimeMonitor();
      monitor.update(LocalRuntimeStatus.ready);
      expect(monitor.state.message, isNull);
    });

    test('successive updates replace previous state', () {
      final monitor = LocalRuntimeMonitor();
      monitor.update(LocalRuntimeStatus.loading, message: 'a');
      monitor.update(LocalRuntimeStatus.inferencing, message: 'b');
      monitor.update(LocalRuntimeStatus.ready);

      expect(monitor.state.status, LocalRuntimeStatus.ready);
      expect(monitor.state.message, isNull);
    });

    test('all LocalRuntimeStatus values are reachable', () {
      final monitor = LocalRuntimeMonitor();
      for (final status in LocalRuntimeStatus.values) {
        monitor.update(status, message: 'test');
        expect(monitor.state.status, status);
      }
    });
  });
}
