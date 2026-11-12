import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_agent_runner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

class FakeAgentDesktop implements ComputerUseAdapter,
    ComputerUseDesktopTargetSelector {
  @override
  bool get isSupported => true;

  int captures = 0;
  int launches = 0;
  int selections = 0;
  int coordinateSelections = 0;
  final List<(int, int)> selectedLocations = <(int, int)>[];
  int clicks = 0;

  @override
  Future<void> selectWindowAt(int x, int y) async {
    coordinateSelections++;
    selectedLocations.add((x, y));
  }
  int typing = 0;
  int cancellations = 0;
  int presses = 0;
  String? lastText;

  @override
  void cancel() => cancellations++;

  @override
  Future<Uint8List> capturePng() async {
    captures++;
    final bytes = Uint8List(24);
    bytes.setRange(
      0, 8, <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    );
    ByteData.sublistView(bytes)
      ..setUint32(16, 1280)
      ..setUint32(20, 720);
    return bytes;
  }

  @override
  Future<void> openApplication(String app) async => launches++;

  @override
  Future<void> selectForegroundWindow() async => selections++;

  @override
  Future<void> click(int x, int y) async => clicks++;

  @override
  Future<void> typeText(String text) async {
    typing++;
    lastText = text;
  }

  @override
  Future<void> pressKey(String key) async => presses++;

  @override
  Future<bool> verifyTestMarker(String marker) async => false;
}

class QueueAgentPlanner implements ComputerUseAgentPlanner {
  QueueAgentPlanner(this.decisions);

  final List<ComputerUseAgentDecision> decisions;
  final List<ComputerUseAgentObservation> seen =
      <ComputerUseAgentObservation>[];

  @override
  Future<ComputerUseAgentDecision> decide(
    ComputerUseAgentObservation observation,
  ) async {
    seen.add(observation);
    return decisions.removeAt(0);
  }
}

class FakeGoalVerifier implements ComputerUseAgentVerifier {
  FakeGoalVerifier(this.evaluate);

  final Future<bool> Function(ComputerUseAgentObservation) evaluate;
  int calls = 0;

  @override
  Future<bool> isSatisfied(ComputerUseAgentObservation observation) {
    calls++;
    return evaluate(observation);
  }
}

class HeldPlanner
    implements ComputerUseAgentPlanner, ComputerUseCancellablePlanner {
  int cancellationCalls = 0;

  @override
  void cancel() => cancellationCalls++;

  final Completer<ComputerUseAgentDecision> held =
      Completer<ComputerUseAgentDecision>();

  @override
  Future<ComputerUseAgentDecision> decide(
    ComputerUseAgentObservation observation,
  ) => held.future;
}

void main() {
  const open = ComputerUseAgentDecision.act(
    'open_app', <String, dynamic>{'app': 'notepad'},
  );
  const select = ComputerUseAgentDecision.act(
    'select_window', <String, dynamic>{},
  );
  const enter = ComputerUseAgentDecision.act(
    'type_text', <String, dynamic>{'text': 'hello-test'},
  );

  group('ComputerUseAgentRunner', () {
    test('no host grant means no observations and no planner calls', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      final planner = QueueAgentPlanner(<ComputerUseAgentDecision>[open]);
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final result = await runner.run(goal: 'Write a demo note');
      expect(result.outcome, ComputerUseAgentOutcome.unauthorized);
      expect(result.steps, 0);
      expect(planner.seen, isEmpty);
      expect(desktop.captures, 0);
      expect(desktop.launches, 0);
    });

    test('dynamic plan chooses actions from new observations', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(
        <ComputerUseAgentDecision>[open, select, enter],
      );
      final verifier = FakeGoalVerifier(
        (_) async => desktop.lastText == 'hello-test',
      );
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: verifier,
      );
      final result = await runner.run(goal: 'Write a demo note');
      expect(result.outcome, ComputerUseAgentOutcome.verified);
      expect(result.steps, 3);
      expect(desktop.launches, 1);
      expect(desktop.selections, 1);
      expect(desktop.typing, 1);
      expect(verifier.calls, 3);
      expect(planner.seen.length, 3);
      expect(planner.seen.last.lastAction, 'select_window');
    });

    test('agent can choose two different windows without intermediate click',
        () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(<ComputerUseAgentDecision>[
        const ComputerUseAgentDecision.act(
          'select_window_at', <String, dynamic>{'x': 80, 'y': 90},
        ),
        const ComputerUseAgentDecision.act(
          'select_window_at', <String, dynamic>{'x': 750, 'y': 440},
        ),
        enter,
      ]);
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => desktop.typing == 1),
      );
      final result = await runner.run(goal: 'Move between test applications');
      expect(result.outcome, ComputerUseAgentOutcome.verified);
      expect(desktop.coordinateSelections, 2);
      expect(desktop.selectedLocations, <(int, int)>[(80, 90), (750, 440)]);
      expect(desktop.clicks, 0);
      expect(desktop.typing, 1);
    });

    test('planner claims completion but verifier rejects it', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(<ComputerUseAgentDecision>[
        const ComputerUseAgentDecision.complete(),
        const ComputerUseAgentDecision.abort(),
      ]);
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final result = await runner.run(goal: 'Prove completion');
      expect(result.outcome, ComputerUseAgentOutcome.stopped);
      expect(result.steps, 1);
      expect(planner.seen.last.lastError, 'GOAL_UNVERIFIED');
    });

    test('unknown action never reaches the host adapter', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(<ComputerUseAgentDecision>[
        const ComputerUseAgentDecision.act(
          'execute_shell', <String, dynamic>{'command': 'anything'},
        ),
        open,
      ]);
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => desktop.launches == 1),
      );
      final result = await runner.run(goal: 'Open a test program');
      expect(result.outcome, ComputerUseAgentOutcome.verified);
      expect(result.steps, 2);
      expect(planner.seen.last.lastError, 'ACTION_NOT_ALLOWED');
      expect(desktop.launches, 1);
    });

    test('three identical proposed actions are interrupted', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(
        <ComputerUseAgentDecision>[open, open, open],
      );
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final result = await runner.run(goal: 'Avoid a loop');
      expect(result.outcome, ComputerUseAgentOutcome.repeatedAction);
      expect(result.steps, 2);
      expect(desktop.launches, 2);
    });

    test('max steps bounds a changing plan', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(
        <ComputerUseAgentDecision>[open, select, enter],
      );
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
        maxSteps: 2,
      );
      final result = await runner.run(goal: 'Bounded task');
      expect(result.outcome, ComputerUseAgentOutcome.maxSteps);
      expect(result.steps, 2);
      expect(desktop.typing, 0);
    });

    test('revoking and regranting during reasoning cannot resurrect task',
        () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = HeldPlanner();
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final pending = runner.run(goal: 'Do not act after revocation');
      await Future<void>.delayed(Duration.zero);
      runner.stop();
      expect(planner.cancellationCalls, 1);
      session.beginSession(allowInteraction: true);
      planner.held.complete(open);
      final result = await pending;
      expect(result.outcome, ComputerUseAgentOutcome.stopped);
      expect(desktop.launches, 0);
      expect(session.isActive, isTrue);
    });

    test('a concurrent second goal cannot start', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = HeldPlanner();
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final pending = runner.run(goal: 'First task');
      await Future<void>.delayed(Duration.zero);
      final second = await runner.run(goal: 'Second task');
      expect(second.outcome, ComputerUseAgentOutcome.busy);
      runner.stop();
      planner.held.complete(open);
      final first = await pending;
      expect(first.outcome, ComputerUseAgentOutcome.stopped);
    });

    test('typed content is never echoed into planner history', () async {
      final desktop = FakeAgentDesktop();
      final session = ComputerUseSession(adapter: desktop);
      session.beginSession(allowInteraction: true);
      final planner = QueueAgentPlanner(<ComputerUseAgentDecision>[
        const ComputerUseAgentDecision.act(
          'type_text', <String, dynamic>{'text': 'demo-value'},
        ),
        const ComputerUseAgentDecision.abort(),
      ]);
      final runner = ComputerUseAgentRunner(
        session: session,
        planner: planner,
        verifier: FakeGoalVerifier((_) async => false),
      );
      final result = await runner.run(goal: 'Sensitive diagnostics check');
      expect(result.outcome, ComputerUseAgentOutcome.stopped);
      expect(planner.seen.last.lastAction, 'type_text');
      expect(planner.seen.last.lastError, isNull);
      expect(desktop.lastText, 'demo-value');
    });
  });
}
