import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_composer.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  group('WorkshopRoleInferenceComposer', () {
    test('builds exactly one gateway for every Workshop role', () {
      final provider = _NoopRuntimeInferenceProvider();
      final builtRoles = <AppAiRole>[];

      final router = WorkshopRoleInferenceComposer.compose(
        gatewayFactory: (role) {
          builtRoles.add(role);
          return WorkshopInferenceGateway(provider: provider);
        },
      );

      expect(
        builtRoles.toSet(),
        WorkshopRoleInferenceRouter.workshopRoles,
      );
      expect(builtRoles.length, 4);
      expect(router.roles, WorkshopRoleInferenceRouter.workshopRoles);
    });

    test('never asks the gateway factory for the Assistant role', () {
      final provider = _NoopRuntimeInferenceProvider();

      WorkshopRoleInferenceComposer.compose(
        gatewayFactory: (role) {
          expect(role, isNot(AppAiRole.assistantOrchestrator));
          return WorkshopInferenceGateway(provider: provider);
        },
      );
    });

    test('keeps the gateway selected for each logical role', () {
      final providers = <AppAiRole, _NoopRuntimeInferenceProvider>{};
      final gateways = <AppAiRole, WorkshopInferenceGateway>{};

      final router = WorkshopRoleInferenceComposer.compose(
        gatewayFactory: (role) {
          final provider = _NoopRuntimeInferenceProvider();
          final gateway = WorkshopInferenceGateway(provider: provider);
          providers[role] = provider;
          gateways[role] = gateway;
          return gateway;
        },
      );

      for (final role in WorkshopRoleInferenceRouter.workshopRoles) {
        expect(router.gatewayFor(role), same(gateways[role]));
        expect(providers.containsKey(role), isTrue);
      }
    });
  });
}

final class _NoopRuntimeInferenceProvider
    implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}
