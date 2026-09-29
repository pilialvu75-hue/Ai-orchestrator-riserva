import 'dart:async';
import 'dart:convert';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_executor.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stage_role_inference.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:http/http.dart' as http;

enum WorkshopWebCloudCapability {
  orchestration('orchestration'),
  architectureReasoning('architecture_reasoning'),
  coding('coding'),
  review('review');

  const WorkshopWebCloudCapability(this.id);
  final String id;
}

abstract final class WorkshopWebCloudRolePolicy {
  static WorkshopWebCloudCapability capabilityForRole(AppAiRole role) {
    return switch (role) {
      AppAiRole.workshopOrchestrator =>
        WorkshopWebCloudCapability.orchestration,
      AppAiRole.architect =>
        WorkshopWebCloudCapability.architectureReasoning,
      AppAiRole.engineer => WorkshopWebCloudCapability.coding,
      AppAiRole.reviewer => WorkshopWebCloudCapability.review,
      AppAiRole.assistantOrchestrator => throw StateError(
          'Assistant role cannot use the Cantiere Web Cloud broker.',
        ),
    };
  }
}

final class WorkshopWebCloudBrokerHealth {
  const WorkshopWebCloudBrokerHealth({
    required this.capabilities,
    this.errorCode,
  });

  final Set<WorkshopWebCloudCapability> capabilities;
  final String? errorCode;

  static const Set<WorkshopWebCloudCapability> requiredWorkshopCapabilities =
      <WorkshopWebCloudCapability>{
    WorkshopWebCloudCapability.orchestration,
    WorkshopWebCloudCapability.architectureReasoning,
    WorkshopWebCloudCapability.coding,
    WorkshopWebCloudCapability.review,
  };

  bool get isReady =>
      errorCode == null &&
      capabilities.containsAll(requiredWorkshopCapabilities);
}

final class WorkshopWebCloudBrokerClient {
  WorkshopWebCloudBrokerClient({
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  final Duration timeout;

  Uri get capabilitiesEndpoint =>
      _baseUri.resolve('/api/cantiere/capabilities');

  Future<WorkshopWebCloudBrokerHealth> health() async {
    try {
      final response = await _client
          .get(
            capabilitiesEndpoint,
            headers: const <String, String>{
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        return WorkshopWebCloudBrokerHealth(
          capabilities: const <WorkshopWebCloudCapability>{},
          errorCode: 'http_${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return const WorkshopWebCloudBrokerHealth(
          capabilities: <WorkshopWebCloudCapability>{},
          errorCode: 'invalid_payload',
        );
      }

      final rawCapabilities = decoded['capabilities'];
      if (rawCapabilities is! List) {
        return const WorkshopWebCloudBrokerHealth(
          capabilities: <WorkshopWebCloudCapability>{},
          errorCode: 'invalid_payload',
        );
      }

      final ids = rawCapabilities.whereType<String>().toSet();
      final resolved = <WorkshopWebCloudCapability>{
        for (final capability in WorkshopWebCloudCapability.values)
          if (ids.contains(capability.id)) capability,
      };

      return WorkshopWebCloudBrokerHealth(
        capabilities: Set<WorkshopWebCloudCapability>.unmodifiable(resolved),
      );
    } on TimeoutException {
      return const WorkshopWebCloudBrokerHealth(
        capabilities: <WorkshopWebCloudCapability>{},
        errorCode: 'timeout',
      );
    } on Object {
      return const WorkshopWebCloudBrokerHealth(
        capabilities: <WorkshopWebCloudCapability>{},
        errorCode: 'unreachable',
      );
    }
  }
}

/// Browser-safe RuntimeInferenceProvider that delegates one Cantiere
/// capability to the same-origin server-side broker.
///
/// The browser never selects an upstream endpoint, provider API key or concrete
/// model. AUTO routing is owned by the server configuration.
final class WorkshopWebCloudRuntimeProvider
    implements RuntimeInferenceProvider {
  WorkshopWebCloudRuntimeProvider({
    required this.capability,
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 90),
  })  : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.base;

  final WorkshopWebCloudCapability capability;
  final http.Client _client;
  final Uri _baseUri;
  final Duration timeout;

  Uri get inferenceEndpoint =>
      _baseUri.resolve('/api/cantiere/inference');

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    if (request.isOffline) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud is unavailable in explicit offline mode.',
        state: InferenceTerminalState.modelUnavailable,
        providerId: 'web_auto',
      );
      return;
    }

    if (cancellationToken.isCancelled) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud request cancelled.',
        state: InferenceTerminalState.cancelled,
        providerId: 'web_auto',
      );
      return;
    }

    final payload = <String, Object?>{
      'version': 1,
      'capability': capability.id,
      'messages': _messagesFor(request),
      'maxTokens': request.maxTokens,
      'temperature': request.temperature,
      'topP': request.topP,
      if (request.requestId?.trim().isNotEmpty == true)
        'requestId': request.requestId!.trim(),
      if (request.projectId?.trim().isNotEmpty == true)
        'projectId': request.projectId!.trim(),
      if (request.taskId?.trim().isNotEmpty == true)
        'taskId': request.taskId!.trim(),
      if (request.executionId?.trim().isNotEmpty == true)
        'executionId': request.executionId!.trim(),
      if (request.attemptId?.trim().isNotEmpty == true)
        'attemptId': request.attemptId!.trim(),
      if (request.checkpointId?.trim().isNotEmpty == true)
        'checkpointId': request.checkpointId!.trim(),
    };

    http.Response response;
    try {
      response = await _client
          .post(
            inferenceEndpoint,
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on TimeoutException {
      yield InferenceResponse.error(
        'Cantiere Web Cloud request timed out.',
        state: InferenceTerminalState.timeout,
        providerId: 'web_auto',
      );
      return;
    } on Object {
      yield InferenceResponse.error(
        'Cantiere Web Cloud broker is unreachable.',
        providerId: 'web_auto',
      );
      return;
    }

    if (cancellationToken.isCancelled) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud request cancelled.',
        state: InferenceTerminalState.cancelled,
        providerId: 'web_auto',
      );
      return;
    }

    if (response.statusCode != 200) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud broker failed (HTTP ${response.statusCode}).',
        providerId: 'web_auto',
      );
      return;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      yield InferenceResponse.error(
        'Cantiere Web Cloud broker returned invalid JSON.',
        providerId: 'web_auto',
      );
      return;
    }

    if (decoded is! Map) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud broker returned an invalid payload.',
        providerId: 'web_auto',
      );
      return;
    }

    final text = decoded['text'];
    if (text is! String || text.trim().isEmpty) {
      yield InferenceResponse.error(
        'Cantiere Web Cloud broker returned an empty response.',
        providerId: 'web_auto',
      );
      return;
    }

    final rawTokens = decoded['tokensGenerated'];
    final tokens = rawTokens is num && rawTokens.isFinite && rawTokens >= 0
        ? rawTokens.toInt()
        : 0;
    final rawModel = decoded['model'];
    final model = rawModel is String && rawModel.trim().isNotEmpty
        ? rawModel.trim()
        : null;

    yield InferenceResponse.finalChunk(
      text: text.trim(),
      tokensGenerated: tokens,
      model: model,
      providerId: 'web_auto',
    );
  }

  static List<Map<String, String>> _messagesFor(
    InferenceRequest request,
  ) {
    final messages = <Map<String, String>>[];

    final systemPrompt = request.systemPrompt?.trim();
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(<String, String>{
        'role': 'system',
        'content': systemPrompt,
      });
    }

    for (final turn in request.context) {
      if (turn.excludeFromContext) continue;
      final content = turn.content.trim();
      if (content.isEmpty) continue;
      messages.add(<String, String>{
        'role': switch (turn.role) {
          ChatRole.user => 'user',
          ChatRole.assistant => 'assistant',
          ChatRole.system => 'system',
        },
        'content': content,
      });
    }

    messages.add(<String, String>{
      'role': 'user',
      'content': request.prompt.trim(),
    });

    return List<Map<String, String>>.unmodifiable(messages);
  }
}

/// Builds the existing role-aware Cantiere inference stack over the Web broker.
abstract final class WorkshopWebCloudAutoFactory {
  static WorkshopStageRoleInference createStageInference({
    required http.Client client,
    Uri? baseUri,
  }) {
    final gateways = <AppAiRole, WorkshopInferenceGateway>{
      for (final role in WorkshopRoleInferenceRouter.workshopRoles)
        role: WorkshopInferenceGateway(
          provider: WorkshopWebCloudRuntimeProvider(
            capability: WorkshopWebCloudRolePolicy.capabilityForRole(role),
            client: client,
            baseUri: baseUri,
          ),
        ),
    };

    return WorkshopStageRoleInference(
      executor: WorkshopRoleInferenceExecutor(
        router: WorkshopRoleInferenceRouter(gateways: gateways),
      ),
    );
  }
}
