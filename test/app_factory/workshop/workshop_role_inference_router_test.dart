import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeRuntimeInferenceProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}

WorkshopInferenceGateway _gateway() {
  return WorkshopInferenceGateway(
    provider: _FakeRuntimeInferenceProvider(),
  );
}

Map<AppAiRole, WorkshopInferenceGateway> _completeGateways() {
  return <AppAiRole, WorkshopInferenceGateway>{
    AppAiRole.workshopOrchestrator: _gateway(),
    AppAiRole.architect: _gateway(),
    AppAiRole.engineer: _gateway(),
    AppAiRole.reviewer: _gateway(),
  };
}

void main() {
  group('WorkshopRoleInferenceRouter', () {
    test('routes every Workshop role to its configured gateway', () {
      final gateways = _completeGateways();
      final router = WorkshopRoleInferenceRouter(gateways: gateways);

      for (final role in WorkshopRoleInferenceRouter.workshopRoles) {
        expect(router.hasRole(role), isTrue);
        expect(router.gatewayFor(role), same(gateways[role]));
      }
    });

    test('rejects Assistant role at construction boundary', () {
      final gateways = _completeGateways()
        ..[AppAiRole.assistantOrchestrator] = _gateway();

      expect(
        () => WorkshopRoleInferenceRouter(gateways: gateways),
        throwsArgumentError,
      );
    });

    test('rejects incomplete Workshop role configuration', () {
      final gateways = _completeGateways()
        ..remove(AppAiRole.reviewer);

      expect(
        () => WorkshopRoleInferenceRouter(gateways: gateways),
        throwsArgumentError,
      );
    });

    test('exposes an immutable configured role set', () {
      final router = WorkshopRoleInferenceRouter(
        gateways: _completeGateways(),
      );

      expect(
        () => router.roles.add(AppAiRole.assistantOrchestrator),
        throwsUnsupportedError,
      );
    });
  });
}
