import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_composition.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_role_inference_router.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

void main() {
  group('WorkshopRoleInferenceComposition', () {
    test('builds one gateway for each Workshop role and no Assistant gateway',
        () {
      final requestedRoles = <AppAiRole>[];

      final executor = WorkshopRoleInferenceComposition.create(
        gatewayBuilder: (role) {
          requestedRoles.add(role);
          return WorkshopInferenceGateway(
            provider: _NoopProvider(),
          );
        },
      );

      expect(
        requestedRoles.toSet(),
        WorkshopRoleInferenceRouter.workshopRoles,
      );
      expect(requestedRoles, hasLength(4));
      expect(
        requestedRoles,
        isNot(contains(AppAiRole.assistantOrchestrator)),
      );
      expect(
        executor.roles,
        WorkshopRoleInferenceRouter.workshopRoles,
      );
    });

    test('creates distinct gateways for the four Workshop roles', () {
      final gateways = <AppAiRole, WorkshopInferenceGateway>{};

      final executor = WorkshopRoleInferenceComposition.create(
        gatewayBuilder: (role) {
          final gateway = WorkshopInferenceGateway(
            provider: _NoopProvider(),
          );
          gateways[role] = gateway;
          return gateway;
        },
      );

      for (final role in WorkshopRoleInferenceRouter.workshopRoles) {
        expect(
          identical(executor.gatewayFor(role), gateways[role]),
          isTrue,
        );
      }

      expect(gateways.values.toSet(), hasLength(4));
    });

    test('Assistant remains rejected by the composed execution boundary', () {
      final executor = WorkshopRoleInferenceComposition.create(
        gatewayBuilder: (_) => WorkshopInferenceGateway(
          provider: _NoopProvider(),
        ),
      );

      expect(
        () => executor.gatewayFor(AppAiRole.assistantOrchestrator),
        throwsStateError,
      );
    });
  });
}

final class _NoopProvider implements RuntimeInferenceProvider {
  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) {
    return const Stream.empty();
  }
}
