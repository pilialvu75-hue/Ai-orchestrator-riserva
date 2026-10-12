import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_canary_coordinator.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canary coordinator exposes only acceleration backend capability', () {
    expect(
      WorkshopLibraryEvolutionCanaryCoordinator.canaryCapability,
      'ai.acceleration_backend',
    );
  });
  test('production factory composes an evolution canary coordinator', () {
    final coordinator =
        WorkshopFactory.createLibraryEvolutionCanaryCoordinator(
          inferenceService: _UninvokedInferenceService(),
        );
    expect(coordinator, isA<WorkshopLibraryEvolutionCanaryCoordinator>());
  });

}

/// Composition-only stub: no native or cloud provider is resolved.
class _UninvokedInferenceService implements InferenceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
