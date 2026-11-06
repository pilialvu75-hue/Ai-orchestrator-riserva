import 'dart:async';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_request.dart';
import 'package:ai_orchestrator/core/ai/entities/ai_response.dart';
import 'package:ai_orchestrator/core/error/failures.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_journal.dart';
import 'package:ai_orchestrator/core/runtime/background/cloud_background_execution_lease.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/cloud_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_consent_denied.dart';
import 'package:ai_orchestrator/core/runtime/inference/directive_aware_inference_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_session_manager.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cloudOnly never falls back to the selected local model', () async {
    var selectedModelLoads = 0;
    var cloudCalls = 0;
    var localCalls = 0;

    const localModel = AiModel(
      id: 'gemma_2b',
      displayName: 'Gemma 2B',
      fileName: 'gemma.gguf',
      downloadUrl: 'https://example.com/model.gguf',
      version: '1.0.0',
      sizeBytes: 123,
      description: 'Test model',
      isDownloaded: true,
      localPath: '/tmp/gemma.gguf',
      validationStatus: ModelValidationStatus.validatedOk,
    );

    final localProvider = _CountingLocalRuntimeProvider(
      onStream: () {
        localCalls += 1;
      },
    );

    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async {
        cloudCalls += 1;
        throw const ServerFailure(
          'OpenAI API error 401: invalid_api_key',
        );
      },
      supportedProviders: () => const <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'OpenAI',
      automaticUseAllowed: (_) => true,
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async {
        selectedModelLoads += 1;
        return localModel;
      },
      loadRuntimeMode: () async => AiRuntimeMode.hybrid,
      runtimeProvider: localProvider,
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
    );

    final chunks = await service
        .stream(
          const InferenceRequest(
            sessionId: 'cloud-only-no-local-fallback',
            prompt: 'hello',
            routeDirective: InferenceRouteDirective.cloudOnly,
            cloudProviderId: 'openAi',
            allowCloudProviderFailover: false,
          ),
        )
        .toList();

    expect(chunks, isNotEmpty);
    expect(chunks.last.isError, isTrue);
    expect(cloudCalls, 1);
    expect(localCalls, 0);
    expect(selectedModelLoads, 0);
  });

  test('explicit CLOUD keeps legacy providers while HYBRID uses reviewed Cloud',
      () async {
    var mode = AiRuntimeMode.cloud;
    var legacyCalls = 0;
    var approvedCalls = 0;
    final local = _CountingLocalRuntimeProvider(onStream: () {
      fail('An explicit Cloud directive must not execute LOCAL');
    });
    final ordinary = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async {
        legacyCalls++;
        expect(provider, 'nvidiaNim');
        return AiResponse(
          text: 'Ordinary NVIDIA answer',
          model: 'model-nvidia-test',
          tokensUsed: 2,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      },
      supportedProviders: () => <String>['nvidiaNim'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'NVIDIA',
      preferredProvider: () => 'nvidiaNim',
      automaticUseAllowed: (_) => true,
    );
    final reviewed = CloudRuntimeProvider(
      consentGated: true,
      sendQuery: (_, __) async {
        fail('HYBRID must never call unreviewed Cloud transport');
        throw StateError('Unreviewed Cloud');
      },
      consentGatedSend: (source, outbound, token) async {
        // The real coordinator rejects unsupported pinned destinations even
        // when the provider catalog contains a permitted alternative.
        if (source.cloudProviderId != outbound.providerId) {
          throw const HybridCloudConsentDenied();
        }
        approvedCalls++;
        expect(outbound.providerId, 'openAi');
        return AiResponse(
          text: 'Reviewed HYBRID answer',
          model: 'gpt-test',
          tokensUsed: 3,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      },
      supportedProviders: () => <String>['openAi'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([name]) => name ?? 'OpenAI',
      preferredProvider: () => 'openAi',
      modelForProvider: (_) => 'gpt-test',
      automaticUseAllowed: (_) => true,
    );
    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => mode,
      runtimeProvider: local,
      cloudRuntimeProvider: ordinary,
      hybridConsentCloudRuntimeProvider: reviewed,
      sessionManager: RuntimeSessionManager(),
    );

    final cloud = await service.stream(const InferenceRequest(
      sessionId: 'explicit-cloud-with-hybrid-qa-on',
      prompt: 'Test existing NVIDIA Cloud',
      routeDirective: InferenceRouteDirective.cloudOnly,
      cloudProviderId: 'nvidiaNim',
      allowCloudProviderFailover: false,
    )).toList();
    expect(cloud.last.isError, isFalse);
    expect(cloud.last.text, 'Ordinary NVIDIA answer');
    expect(legacyCalls, 1);
    expect(approvedCalls, 0);

    // A runtimeDefault request in ordinary CLOUD also keeps the original
    // provider; it cannot accidentally go through the HYBRID gate.
    final defaultCloud = await service.stream(const InferenceRequest(
      sessionId: 'default-cloud-with-hybrid-qa-on',
      prompt: 'Test regular Cloud fallback selection',
    )).toList();
    expect(defaultCloud.last.text, 'Ordinary NVIDIA answer');
    expect(legacyCalls, 2);
    expect(approvedCalls, 0);

    mode = AiRuntimeMode.hybrid;
    final hybrid = await service.stream(const InferenceRequest(
      sessionId: 'protected-hybrid',
      prompt: 'Test guarded Cloud choice',
      routeDirective: InferenceRouteDirective.cloudOnly,
      cloudProviderId: 'openAi',
      allowCloudProviderFailover: false,
    )).toList();
    expect(hybrid.last.isError, isFalse);
    expect(hybrid.last.text, 'Reviewed HYBRID answer');
    expect(approvedCalls, 1);
    expect(legacyCalls, 2);

    // An unsupported provider in HYBRID must fail closed instead of
    // silently using the normal NVIDIA Cloud transport.
    final denied = await service.stream(const InferenceRequest(
      sessionId: 'unsupported-protected-provider',
      prompt: 'Do not select unreviewed NVIDIA silently',
      routeDirective: InferenceRouteDirective.cloudOnly,
      cloudProviderId: 'nvidiaNim',
      allowCloudProviderFailover: false,
    )).toList();
    expect(denied.last.isError, isTrue);
    expect(approvedCalls, 1);
    expect(legacyCalls, 2);
  });

  test('cloudOnly holds one Android background lease until stream completion',
      () async {
    const channel = MethodChannel('test/cloud_background_execution');
    final methodCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methodCalls.add(call);
      return <String, Object>{'ok': true};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final localProvider = _CountingLocalRuntimeProvider(onStream: () {});
    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async => AiResponse(
        text: 'cloud answer',
        model: 'test-cloud-model',
        tokensUsed: 4,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'Gemini',
      automaticUseAllowed: (_) => true,
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => AiRuntimeMode.cloud,
      runtimeProvider: localProvider,
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
      backgroundExecutionLeaseService: CloudBackgroundExecutionLeaseService(
        channel: channel,
        platformOverride: TargetPlatform.android,
      ),
    );

    final chunks = await service
        .stream(
          const InferenceRequest(
            sessionId: 'background-cloud',
            prompt: 'hello',
            routeDirective: InferenceRouteDirective.cloudOnly,
            cloudProviderId: 'gemini',
            allowCloudProviderFailover: false,
          ),
        )
        .toList();

    expect(chunks.last.text, 'cloud answer');
    expect(methodCalls.map((call) => call.method).toList(), <String>[
      'acquire',
      'release',
    ]);
    expect(
      (methodCalls.first.arguments as Map<Object?, Object?>)['sessionId'],
      'background-cloud',
    );
    expect(
      (methodCalls.first.arguments as Map<Object?, Object?>)['provider'],
      'gemini',
    );
  });

  test('cloudOnly journals concrete AUTO provider before stream settles',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final journal = CloudBackgroundExecutionJournal(
      preferences: preferences,
      bootId: 'boot-current',
    );

    final localProvider = _CountingLocalRuntimeProvider(onStream: () {});
    final cloudProvider = CloudRuntimeProvider(
      sendQuery: (String provider, AiRequest request) async => AiResponse(
        text: 'cloud answer',
        model: 'test-cloud-model',
        tokensUsed: 4,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
      supportedProviders: () => const <String>['gemini'],
      isProviderAvailable: (_) => true,
      providerDisplayName: ([providerName]) => 'Gemini',
      automaticUseAllowed: (_) => true,
    );

    final service = DirectiveAwareInferenceService(
      loadSelectedModel: () async => null,
      loadRuntimeMode: () async => AiRuntimeMode.cloud,
      runtimeProvider: localProvider,
      cloudRuntimeProvider: cloudProvider,
      sessionManager: RuntimeSessionManager(),
      backgroundExecutionJournal: journal,
    );

    final iterator = StreamIterator<InferenceResponse>(
      service.stream(
        const InferenceRequest(
          sessionId: 'background-auto-provider',
          prompt: 'hello',
          requestId: 'request-auto-provider',
          routeDirective: InferenceRouteDirective.cloudOnly,
        ),
      ),
    );

    InferenceResponse? providerChunk;
    while (await iterator.moveNext()) {
      if (iterator.current.providerId != null) {
        providerChunk = iterator.current;
        break;
      }
    }

    expect(providerChunk, isNotNull);
    expect(providerChunk!.providerId, 'gemini');

    final inFlight = await journal.snapshot();
    expect(inFlight, hasLength(1));
    expect(inFlight.single.providerHint, 'auto');
    expect(inFlight.single.providerId, 'gemini');

    while (await iterator.moveNext()) {}
    expect(await journal.snapshot(), isEmpty);
  });
}

final class _CountingLocalRuntimeProvider extends LocalRuntimeProvider {
  _CountingLocalRuntimeProvider({required this.onStream});

  final void Function() onStream;

  @override
  bool supportsModel(AiModel model) => true;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    onStream();
    yield InferenceResponse.finalChunk(
      text: 'unexpected local response',
      tokensGenerated: 1,
      model: request.modelId ?? 'local',
    );
  }
}
