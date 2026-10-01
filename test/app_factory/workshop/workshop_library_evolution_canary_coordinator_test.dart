import 'package:ai_orchestrator/app_factory/workshop/workshop_library_evolution_canary_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canary coordinator exposes only acceleration backend capability', () {
    expect(
      WorkshopLibraryEvolutionCanaryCoordinator.canaryCapability,
      'ai.acceleration_backend',
    );
  });
}
