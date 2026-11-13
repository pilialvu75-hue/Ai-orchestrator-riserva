import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_aivexus_local_decision_model.dart';

final class FakeComputerUseLocalRuntime extends LocalRuntimeProvider {
  FakeComputerUseLocalRuntime(this.responses);

  final List<InferenceResponse> responses;
  InferenceRequest? request;
  CancellationToken? cancellation;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    this.request = request;
    cancellation = cancellationToken;
    for (final chunk in responses) {
      yield chunk;
    }
  }
}

final class HeldComputerUseLocalRuntime extends LocalRuntimeProvider {
  final Completer<InferenceResponse> pending = Completer<InferenceResponse>();
  CancellationToken? cancellation;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    cancellation = cancellationToken;
    yield await pending.future;
  }
}

void main() {
  AivexusComputerUseLocalDecisionModel model(LocalRuntimeProvider runtime) =>
      AivexusComputerUseLocalDecisionModel(
        localRuntime: runtime,
        modelId: 'test-local-model',
        modelPath: '/local/test.gguf',
        sessionId: 'computer-use-test-session',
      );

  test('sends Computer Use decisions exclusively through LOCAL route',
      () async {
    final runtime = FakeComputerUseLocalRuntime(<InferenceResponse>[
      InferenceResponse.token(text: '{"status":'),
      InferenceResponse.token(text: '"complete"}'),
      InferenceResponse.finalChunk(
        text: '{"status":"complete"}',
        tokensGenerated: 8,
      ),
    ]);
    final output = await model(runtime).completeLocally(
      systemInstruction: 'Strict JSON only',
      userPayload: 'Select another app',
    );
    expect(output, '{"status":"complete"}');
    final request = runtime.request!;
    expect(request.routeDirective, InferenceRouteDirective.localOnly);
    expect(request.isOffline, isTrue);
    expect(request.allowWebSearchTool, isFalse);
    expect(request.allowCloudProviderFailover, isFalse);
    expect(request.cloudProviderId, isNull);
    expect(request.modelId, 'test-local-model');
    expect(request.modelPath, '/local/test.gguf');
    expect(request.systemPrompt, 'Strict JSON only');
    expect(request.prompt, 'Select another app');
    expect(request.maxTokens, 256);
    expect(request.preserveMaxTokens, isTrue);
  });

  test('inference error cannot be accepted as a decision', () async {
    final runtime = FakeComputerUseLocalRuntime(<InferenceResponse>[
      InferenceResponse.error('runtime unavailable'),
    ]);
    await expectLater(
      model(runtime).completeLocally(
        systemInstruction: 'JSON', userPayload: 'Task',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('unfinished LOCAL stream cannot claim success', () async {
    final runtime = FakeComputerUseLocalRuntime(<InferenceResponse>[
      InferenceResponse.token(text: '{"status":"complete"}'),
    ]);
    await expectLater(
      model(runtime).completeLocally(
        systemInstruction: 'JSON', userPayload: 'Task',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('STOP cancels the active LOCAL generation', () async {
    final runtime = HeldComputerUseLocalRuntime();
    final local = model(runtime);
    final pending = local.completeLocally(
      systemInstruction: 'JSON', userPayload: 'Task',
    );
    await Future<void>.delayed(Duration.zero);
    local.cancelPendingCompletion();
    expect(runtime.cancellation?.isCancelled, isTrue);
    runtime.pending.complete(
      InferenceResponse.error('cancelled',
          state: InferenceTerminalState.cancelled),
    );
    await expectLater(pending, throwsA(isA<StateError>()));
  });

  test('cannot call an unconfigured LOCAL model', () async {
    final runtime = FakeComputerUseLocalRuntime(const <InferenceResponse>[]);
    final local = AivexusComputerUseLocalDecisionModel(
      localRuntime: runtime,
      modelId: ' ',
      modelPath: '',
      sessionId: 'test',
    );
    await expectLater(
      local.completeLocally(systemInstruction: 'JSON', userPayload: 'Task'),
      throwsA(isA<StateError>()),
    );
    expect(runtime.request, isNull);
  });
}
