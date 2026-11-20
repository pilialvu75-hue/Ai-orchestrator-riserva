import 'package:ai_orchestrator/core/runtime/inference/hybrid_local_runtime_step_bridge.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('H51 uses localOnly and offline existing inference stream', () async {
    InferenceRequest? captured;
    TokenStream fake(InferenceRequest request) async* {
      captured = request;
      yield InferenceResponse.token(text: 'risposta ', model: 'qwen-local');
      yield InferenceResponse.finalChunk(
        text: 'risposta completa', tokensGenerated: 3, model: 'qwen-local');
    }
    final bridge = HybridLocalRuntimeStepBridge(
      stream: fake, sessionId: 'chat1', taskId: 'task1');
    final result = await bridge.execute('second stage', ['verified first']);
    expect(result.output, 'risposta completa');
    expect(result.provenance, 'local-runtime:qwen-local');
    expect(captured!.routeDirective, InferenceRouteDirective.localOnly);
    expect(captured!.isOffline, isTrue);
    expect(captured!.allowWebSearchTool, isFalse);
    expect(captured!.cloudProviderId, isNull);
    expect(captured!.allowCloudProviderFailover, isFalse);
    expect(captured!.prompt, contains('verified first'));
  });

  test('H51 missing final chunk cannot be committed', () async {
    TokenStream fake(InferenceRequest request) async* {
      yield InferenceResponse.token(text: 'partial');
    }
    final bridge = HybridLocalRuntimeStepBridge(
      stream: fake, sessionId: 'chat1', taskId: 'task1');
    await expectLater(bridge.execute('run', []), throwsStateError);
  });

  test('H51 rejected timeout and Cloud-labelled output', () async {
    TokenStream timedOut(InferenceRequest request) async* {
      yield InferenceResponse.error(
        'timeout', state: InferenceTerminalState.timeout);
    }
    TokenStream cloudTagged(InferenceRequest request) async* {
      yield InferenceResponse.finalChunk(
        text: 'wrong', tokensGenerated: 1, providerId: 'gemini');
    }
    await expectLater(HybridLocalRuntimeStepBridge(
      stream: timedOut, sessionId: 'chat1', taskId: 'task1',
    ).execute('run', []), throwsStateError);
    await expectLater(HybridLocalRuntimeStepBridge(
      stream: cloudTagged, sessionId: 'chat1', taskId: 'task1',
    ).execute('run', []), throwsStateError);
  });

  test('H51 bounds prior context and protects receipt size', () async {
    var invoked = false;
    TokenStream fake(InferenceRequest request) async* {
      invoked = true;
      yield InferenceResponse.finalChunk(
        text: 'X' * 8193, tokensGenerated: 1);
    }
    final bridge = HybridLocalRuntimeStepBridge(
      stream: fake, sessionId: 'chat1', taskId: 'task1');
    await expectLater(bridge.execute('run', ['X' * 8193]), throwsStateError);
    expect(invoked, isFalse);
    await expectLater(bridge.execute('run', []), throwsStateError);
    expect(invoked, isTrue);
  });

  test('H51 rejects duplicate final chunks and empty final outputs', () async {
    TokenStream duplicate(InferenceRequest request) async* {
      yield InferenceResponse.finalChunk(text: 'answer', tokensGenerated: 1);
      yield InferenceResponse.finalChunk(text: 'answer', tokensGenerated: 1);
    }
    TokenStream empty(InferenceRequest request) async* {
      yield InferenceResponse.finalChunk(text: '', tokensGenerated: 0);
    }
    for (final fake in <TokenStream Function(InferenceRequest)>[duplicate, empty]) {
      await expectLater(HybridLocalRuntimeStepBridge(
        stream: fake, sessionId: 'chat1', taskId: 'task1',
      ).execute('run', []), throwsStateError);
    }
  });
}
