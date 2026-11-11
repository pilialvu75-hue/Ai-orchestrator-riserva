import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_provider_adapter.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

class _RecordingService implements InferenceService {
  InferenceRequest? lastRequest;

  @override
  TokenStream stream(InferenceRequest request) {
    lastRequest = request;
    return Stream<InferenceResponse>.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected InferenceService call: ${invocation.memberName}');
}

void main() {
  test('LOCAL request refuses cloud-assigned Cantiere model before inference',
      () async {
    final service = _RecordingService();
    final adapter = WorkshopInferenceProviderAdapter(
      inferenceService: service,
      role: AppAiRole.engineer,
      modelId: 'nvidia/nemotron-3-ultra-550b-a55b',
    );
    final request = InferenceRequest(
      sessionId: 'local-workshop-test',
      prompt: 'Create a Flutter star.',
      isOffline: true,
    );
    await expectLater(
      adapter.streamInference(
        request: request,
        cancellationToken: CancellationToken(),
      ),
      emitsError(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('cannot route'),
      )),
    );
    expect(service.lastRequest, isNull,
        reason: 'LOCAL must not attempt any underlying cloud inference');
  });

  test('explicit LOCAL route refuses Cloud model even with Internet available',
      () async {
    final service = _RecordingService();
    final adapter = WorkshopInferenceProviderAdapter(
      inferenceService: service,
      role: AppAiRole.engineer,
      modelId: 'nvidia/nemotron-3-ultra-550b-a55b',
    );
    await expectLater(
      adapter.streamInference(
        request: const InferenceRequest(
          sessionId: 'local-internet-enabled',
          prompt: 'Create a Flutter star.',
          isOffline: false,
          routeDirective: InferenceRouteDirective.localOnly,
        ),
        cancellationToken: CancellationToken(),
      ),
      emitsError(isA<StateError>()),
    );
    expect(service.lastRequest, isNull);
  });

  test('local model strips Cloud route and provider even when Internet is enabled',
      () async {
    final service = _RecordingService();
    final adapter = WorkshopInferenceProviderAdapter(
      inferenceService: service,
      role: AppAiRole.engineer,
      modelId: 'qwen2_5_3b_instruct',
    );
    await adapter.streamInference(
      request: const InferenceRequest(
        sessionId: 'local-model-internet-enabled',
        prompt: 'Create a Flutter star.',
        isOffline: false,
        routeDirective: InferenceRouteDirective.cloudOnly,
        cloudProviderId: 'nvidiaNim',
      ),
      cancellationToken: CancellationToken(),
    ).drain<void>();
    expect(service.lastRequest, isNotNull);
    expect(service.lastRequest!.routeDirective, InferenceRouteDirective.localOnly);
    expect(service.lastRequest!.cloudProviderId, isNull);
    expect(service.lastRequest!.isOffline, isFalse);
  });

  test('explicit non-offline cloud Cantiere request keeps provider binding',
      () async {
    final service = _RecordingService();
    final adapter = WorkshopInferenceProviderAdapter(
      inferenceService: service,
      role: AppAiRole.engineer,
      modelId: 'nvidia/nemotron-3-ultra-550b-a55b',
    );
    await adapter.streamInference(
      request: const InferenceRequest(
        sessionId: 'cloud-workshop-test',
        prompt: 'Create a Flutter star.',
      ),
      cancellationToken: CancellationToken(),
    ).drain<void>();
    expect(service.lastRequest, isNotNull);
    expect(service.lastRequest!.routeDirective, InferenceRouteDirective.cloudOnly);
    expect(service.lastRequest!.cloudProviderId, 'nvidiaNim');
  });

  test('offline local model keeps existing local inference path', () async {
    final service = _RecordingService();
    final adapter = WorkshopInferenceProviderAdapter(
      inferenceService: service,
      role: AppAiRole.engineer,
      modelId: 'qwen2_5_3b_instruct',
    );
    await adapter.streamInference(
      request: const InferenceRequest(
        sessionId: 'device-workshop-test',
        prompt: 'Create a Flutter star.',
        isOffline: true,
      ),
      cancellationToken: CancellationToken(),
    ).drain<void>();
    expect(service.lastRequest, isNotNull);
    expect(service.lastRequest!.isOffline, isTrue);
    expect(service.lastRequest!.modelId, 'qwen2_5_3b_instruct');
    expect(service.lastRequest!.routeDirective, InferenceRouteDirective.localOnly);
  });
}
