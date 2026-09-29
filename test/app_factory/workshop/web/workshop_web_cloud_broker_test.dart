import 'dart:convert';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('W4 role policy maps only Cantiere roles to stable capabilities', () {
    expect(
      WorkshopWebCloudRolePolicy.capabilityForRole(
        AppAiRole.workshopOrchestrator,
      ),
      WorkshopWebCloudCapability.orchestration,
    );
    expect(
      WorkshopWebCloudRolePolicy.capabilityForRole(AppAiRole.architect),
      WorkshopWebCloudCapability.architectureReasoning,
    );
    expect(
      WorkshopWebCloudRolePolicy.capabilityForRole(AppAiRole.engineer),
      WorkshopWebCloudCapability.coding,
    );
    expect(
      WorkshopWebCloudRolePolicy.capabilityForRole(AppAiRole.reviewer),
      WorkshopWebCloudCapability.review,
    );
    expect(
      () => WorkshopWebCloudRolePolicy.capabilityForRole(
        AppAiRole.assistantOrchestrator,
      ),
      throwsStateError,
    );
  });

  test('W4 broker health requires every Workshop capability', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/cantiere/capabilities');
      return http.Response(
        jsonEncode(<String, Object>{
          'version': 1,
          'mode': 'auto',
          'capabilities': <String>[
            'orchestration',
            'architecture_reasoning',
            'coding',
            'review',
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final health = await WorkshopWebCloudBrokerClient(
      client: client,
      baseUri: Uri.parse('https://cantiere.example/'),
    ).health();

    expect(health.isReady, isTrue);
    expect(
      health.capabilities,
      containsAll(WorkshopWebCloudBrokerHealth.requiredWorkshopCapabilities),
    );
  });

  test('W4 runtime sends capability, bounded inference data and no upstream',
      () async {
    Map<String, dynamic>? captured;
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/cantiere/inference');
      captured = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, Object>{
          'version': 1,
          'text': 'Validated implementation plan.',
          'model': 'server-selected-model',
          'routeId': 'server-route',
          'tokensGenerated': 7,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final provider = WorkshopWebCloudRuntimeProvider(
      capability: WorkshopWebCloudCapability.coding,
      client: client,
      baseUri: Uri.parse('https://cantiere.example/'),
    );

    final responses = await provider
        .streamInference(
          request: const InferenceRequest(
            sessionId: 'workshop-web-test',
            prompt: 'Implement the validated change.',
            systemPrompt: 'You are the Cantiere Engineer.',
            context: <ChatTurn>[
              ChatTurn(role: ChatRole.user, content: 'Project requirement'),
              ChatTurn(
                role: ChatRole.assistant,
                content: 'Assistant-only stale context',
                excludeFromContext: true,
              ),
            ],
            maxTokens: 640,
            temperature: 0.2,
            topP: 0.8,
            requestId: 'request-1',
            projectId: 'project-1',
            taskId: 'task-1',
          ),
          cancellationToken: CancellationToken(),
        )
        .toList();

    expect(responses, hasLength(1));
    final finalResponse = responses.single;
    expect(finalResponse.isFinal, isTrue);
    expect(finalResponse.terminalState, InferenceTerminalState.success);
    expect(finalResponse.providerId, 'web_auto');
    expect(finalResponse.text, 'Validated implementation plan.');
    expect(finalResponse.model, 'server-selected-model');
    expect(finalResponse.tokensGenerated, 7);

    expect(captured, isNotNull);
    expect(captured!['capability'], 'coding');
    expect(captured!['maxTokens'], 640);
    expect(captured!['temperature'], 0.2);
    expect(captured!['topP'], 0.8);
    expect(captured!['projectId'], 'project-1');

    // The browser sends a capability, never an upstream/provider/model binding.
    expect(captured!.containsKey('provider'), isFalse);
    expect(captured!.containsKey('endpoint'), isFalse);
    expect(captured!.containsKey('apiKey'), isFalse);
    expect(captured!.containsKey('model'), isFalse);

    final messages = captured!['messages'] as List<dynamic>;
    expect(messages, hasLength(3));
    expect((messages.first as Map<String, dynamic>)['role'], 'system');
    expect(
      messages.any(
        (row) => (row as Map<String, dynamic>)['content'] ==
            'Assistant-only stale context',
      ),
      isFalse,
    );
    expect((messages.last as Map<String, dynamic>)['role'], 'user');
  });

  test('W4 explicit offline mode fails before any broker call', () async {
    var calls = 0;
    final provider = WorkshopWebCloudRuntimeProvider(
      capability: WorkshopWebCloudCapability.review,
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      }),
      baseUri: Uri.parse('https://cantiere.example/'),
    );

    final responses = await provider
        .streamInference(
          request: const InferenceRequest(
            sessionId: 'offline',
            prompt: 'Review.',
            isOffline: true,
          ),
          cancellationToken: CancellationToken(),
        )
        .toList();

    expect(calls, 0);
    expect(responses.single.isError, isTrue);
    expect(
      responses.single.terminalState,
      InferenceTerminalState.modelUnavailable,
    );
  });

  test('W4 cancelled request fails closed before broker call', () async {
    var calls = 0;
    final token = CancellationToken()..cancel();
    final provider = WorkshopWebCloudRuntimeProvider(
      capability: WorkshopWebCloudCapability.orchestration,
      client: MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      }),
      baseUri: Uri.parse('https://cantiere.example/'),
    );

    final responses = await provider
        .streamInference(
          request: const InferenceRequest(
            sessionId: 'cancelled',
            prompt: 'Plan.',
          ),
          cancellationToken: token,
        )
        .toList();

    expect(calls, 0);
    expect(responses.single.terminalState, InferenceTerminalState.cancelled);
  });
}
