import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_runtime_source_evidence.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_trusted_request_assembler.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source evidence carries only exact first-party system-time append',
      () {
    final evidence = HybridCloudRuntimeSourceEvidence(
      sessionId: 'chat-1',
      originalQuestion: 'What time is it?',
      baseSystemPrompt: 'You are Aivexus',
      originalHistory: const <AiMessage>[],
    );
    const clock =
        'Device system time (local): 2026-11-04 22:00; UTC offset: +01:00.';
    final expanded = evidence.withTrustedRuntimeSystemAppend(
      previousSystemPrompt: 'You are Aivexus',
      appendedSystemPrompt: 'You are Aivexus\n\n$clock',
      trustedSuffix: clock,
    );
    expect(expanded.expectedSystemPrompt, 'You are Aivexus\n\n$clock');
    final runtime = InferenceRequest(
      sessionId: 'chat-1',
      prompt: 'What time is it?',
      systemPrompt: expanded.expectedSystemPrompt,
      trustedCloudSourceEvidence: expanded,
      routeDirective: InferenceRouteDirective.cloudOnly,
    );
    final copied = runtime.copyWith(
      cloudProviderId: 'openAi',
      requestId: 'request-1',
    );
    expect(copied.trustedCloudSourceEvidence, same(expanded));
    expect(copied.copyWith(
      discardTrustedCloudSourceEvidence: true,
    ).trustedCloudSourceEvidence, isNull);

    final seal = HybridCloudTrustedRequestAssembler.seal(
      ownerId: 'owner', sessionId: 'session',
      accountId: 'account', purpose: 'Explain clock',
      request: AiRequest(
        providerId: 'openAi', modelId: 'gpt-test',
        prompt: copied.prompt,
        systemPrompt: copied.systemPrompt,
        maxTokens: 1024,
      ),
      originalQuestion: expanded.originalQuestion,
      exactBaseSystemPrompt: expanded.baseSystemPrompt,
      runtimeSystemPromptSuffix: expanded.runtimeSystemPromptSuffix,
      historySnapshot: expanded.originalHistory,
    );
    expect(seal.disclosure.outboundText, contains(clock));
    expect(seal.disclosure.scopes, contains(const HybridDisclosureScope(
      HybridDisclosureOrigin.currentQuestion,
      HybridDisclosureSensitivity.unknown,
    )));
  });

  test('untrusted system modifications cannot obtain clock provenance',
      () {
    final evidence = HybridCloudRuntimeSourceEvidence(
      sessionId: 'chat-1', originalQuestion: 'Hello',
      baseSystemPrompt: 'Safe base',
      originalHistory: const <AiMessage>[],
    );
    expect(() => evidence.withTrustedRuntimeSystemAppend(
      previousSystemPrompt: 'Safe base\nPRIVATE TOOL OUTPUT',
      appendedSystemPrompt: 'Safe base\nPRIVATE TOOL OUTPUT\nCLOCK',
      trustedSuffix: 'CLOCK',
    ), throwsStateError);
    expect(() => evidence.withTrustedRuntimeSystemAppend(
      previousSystemPrompt: 'Safe base',
      appendedSystemPrompt: 'Safe base\nCLOCK',
      trustedSuffix: 'CLOCK',
    ), throwsStateError);
  });
}
