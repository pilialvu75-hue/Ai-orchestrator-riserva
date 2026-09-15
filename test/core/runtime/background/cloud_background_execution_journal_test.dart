import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const storageKey = 'cloud_background_execution_journal_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('journal persists recovery identity without prompt or conversation text',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final journal = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-a',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );

    final record = await journal.begin(
      request: const InferenceRequest(
        sessionId: 'session-1',
        prompt: 'SECRET USER PROMPT MUST NOT BE PERSISTED',
        systemPrompt: 'SECRET SYSTEM PROMPT MUST NOT BE PERSISTED',
        requestId: 'request-1',
        projectId: 'project-1',
        taskId: 'task-1',
        executionId: 'execution-1',
        attemptId: 'attempt-2',
        checkpointId: 'checkpoint-3',
        routeDirective: InferenceRouteDirective.cloudOnly,
        cloudProviderId: 'gemini',
      ),
      providerHint: 'gemini',
    );

    expect(record, isNotNull);
    expect(record!.requestId, 'request-1');
    expect(record.projectId, 'project-1');
    expect(record.checkpointId, 'checkpoint-3');

    final raw = preferences.getString(storageKey);
    expect(raw, isNotNull);
    expect(raw, contains('request-1'));
    expect(raw, contains('gemini'));
    expect(raw, isNot(contains('SECRET USER PROMPT')));
    expect(raw, isNot(contains('SECRET SYSTEM PROMPT')));
  });

  test('new process boot consumes an unfinished request once', () async {
    final preferences = await SharedPreferences.getInstance();
    final firstBoot = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-a',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );

    await firstBoot.begin(
      request: const InferenceRequest(
        sessionId: 'session-1',
        prompt: 'hello',
        requestId: 'request-1',
        routeDirective: InferenceRouteDirective.cloudOnly,
      ),
      providerHint: 'auto',
    );

    final secondBoot = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-b',
      clock: () => DateTime.fromMillisecondsSinceEpoch(2000),
    );

    final interrupted =
        await secondBoot.consumeInterruptedForSession('session-1');
    expect(interrupted, hasLength(1));
    expect(interrupted.single.requestId, 'request-1');

    final consumedAgain =
        await secondBoot.consumeInterruptedForSession('session-1');
    expect(consumedAgain, isEmpty);
    expect(await secondBoot.snapshot(), isEmpty);
  });

  test('current-boot request is not mistaken for a previous-process crash',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final journal = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-current',
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );

    final record = await journal.begin(
      request: const InferenceRequest(
        sessionId: 'session-current',
        prompt: 'hello',
        requestId: 'request-current',
        routeDirective: InferenceRouteDirective.cloudOnly,
      ),
      providerHint: 'openRouter',
    );

    expect(
      await journal.consumeInterruptedForSession('session-current'),
      isEmpty,
    );
    expect(await journal.snapshot(), hasLength(1));

    await journal.settle(record);
    expect(await journal.snapshot(), isEmpty);
    expect(preferences.containsKey(storageKey), isFalse);
  });

  test('corrupt persisted journal fails closed without replay metadata',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      storageKey: '{not-json',
    });
    final preferences = await SharedPreferences.getInstance();
    final journal = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-b',
    );

    expect(await journal.snapshot(), isEmpty);
    expect(
      await journal.consumeInterruptedForSession('session-1'),
      isEmpty,
    );
  });
}
