import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_recovery_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = CloudBackgroundRecoveryPolicy();

  test('AUTO recovery always re-enters current spend-safe router', () {
    const record = CloudBackgroundExecutionRecord(
      jobId: 'job-auto',
      bootId: 'boot-a',
      sessionId: 'session-1',
      providerHint: 'auto',
      providerId: 'claude',
      startedAtEpochMs: 1000,
    );

    final decision = policy.decide(record);

    expect(
      decision.retryRoute,
      CloudBackgroundRecoveryRetryRoute.automaticRouter,
    );
    expect(decision.automaticReplayAllowed, isFalse);
    expect(decision.requiresFreshSpendAuthorization, isFalse);
    expect(decision.providerId, 'claude');
    expect(decision.notice, contains('AUTO'));
    expect(decision.notice, contains('free-first/spend-safe'));
  });

  test('pinned recurring-free provider may be retried explicitly', () {
    const record = CloudBackgroundExecutionRecord(
      jobId: 'job-free',
      bootId: 'boot-a',
      sessionId: 'session-1',
      providerHint: 'gemini',
      providerId: 'gemini',
      startedAtEpochMs: 1000,
    );

    final decision = policy.decide(record);

    expect(
      decision.retryRoute,
      CloudBackgroundRecoveryRetryRoute.sameFreeProvider,
    );
    expect(decision.automaticReplayAllowed, isFalse);
    expect(decision.requiresFreshSpendAuthorization, isFalse);
    expect(decision.providerDisplayName, 'Gemini');
  });

  test('pinned paid provider requires fresh per-request authorization', () {
    const record = CloudBackgroundExecutionRecord(
      jobId: 'job-paid',
      bootId: 'boot-a',
      sessionId: 'session-1',
      providerHint: 'claude',
      providerId: 'claude',
      startedAtEpochMs: 1000,
    );

    final decision = policy.decide(record);

    expect(
      decision.retryRoute,
      CloudBackgroundRecoveryRetryRoute.freshExplicitAuthorization,
    );
    expect(decision.automaticReplayAllowed, isFalse);
    expect(decision.requiresFreshSpendAuthorization, isTrue);
    expect(decision.notice, contains('fresh explicit authorization'));
  });

  test('unknown-cost pinned provider fails closed for spend safety', () {
    const record = CloudBackgroundExecutionRecord(
      jobId: 'job-unknown',
      bootId: 'boot-a',
      sessionId: 'session-1',
      providerHint: 'nvidiaNim',
      providerId: 'nvidiaNim',
      startedAtEpochMs: 1000,
    );

    final decision = policy.decide(record);

    expect(
      decision.retryRoute,
      CloudBackgroundRecoveryRetryRoute.freshExplicitAuthorization,
    );
    expect(decision.requiresFreshSpendAuthorization, isTrue);
  });

  test('multiple interrupted requests summarize distinct recovery gates', () {
    const records = <CloudBackgroundExecutionRecord>[
      CloudBackgroundExecutionRecord(
        jobId: 'job-auto',
        bootId: 'boot-a',
        sessionId: 'session-1',
        providerHint: 'auto',
        providerId: 'openRouter',
        startedAtEpochMs: 1000,
      ),
      CloudBackgroundExecutionRecord(
        jobId: 'job-free',
        bootId: 'boot-a',
        sessionId: 'session-1',
        providerHint: 'gemini',
        providerId: 'gemini',
        startedAtEpochMs: 1001,
      ),
      CloudBackgroundExecutionRecord(
        jobId: 'job-paid',
        bootId: 'boot-a',
        sessionId: 'session-1',
        providerHint: 'openAi',
        providerId: 'openAi',
        startedAtEpochMs: 1002,
      ),
    ];

    final notice = policy.noticeFor(records);

    expect(notice, contains('3 previous Cloud responses'));
    expect(notice, contains('1 must retry through AUTO'));
    expect(notice, contains('1 may retry the same recurring-free provider'));
    expect(notice, contains('1 require fresh explicit provider authorization'));
  });
}
