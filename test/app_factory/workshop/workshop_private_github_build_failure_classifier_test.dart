import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_build_provider.dart';

void main() {
  group('WorkshopPrivateBuildFailureClassifier', () {
    test('marks generated-project build steps as repairable classes', () {
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(
          'Resolve dependencies',
        ),
        'remote_dependency_resolution_failed',
      );
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(
          'Validate generated project',
        ),
        'remote_validation_failed',
      );
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(
          'Build Android APK',
        ),
        'remote_project_build_failed',
      );
    });

    test('keeps toolchain and security failures infrastructural', () {
      for (final step in <String?>[
        'Validate dispatch inputs',
        'Checkout staged Cantiere source only',
        'Validate staged source boundary',
        'Setup Java',
        'Setup Flutter',
        'Materialize generic Android scaffold',
        'Package verified artifact',
        'Upload Cantiere APK',
        null,
      ]) {
        expect(
          WorkshopPrivateBuildFailureClassifier.codeForStep(step),
          'remote_infrastructure_failed',
          reason: step,
        );
      }
    });
  });
}
