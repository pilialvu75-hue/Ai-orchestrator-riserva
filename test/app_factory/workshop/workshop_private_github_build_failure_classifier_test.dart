import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_build_provider.dart';

void main() {
  group('WorkshopPrivateBuildFailureClassifier', () {
    test('marks generated-project build steps as repairable classes', () {
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(
          'Validate staged source boundary',
        ),
        'remote_source_boundary_failed',
      );
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


    test('recovers validation step from analyzer diagnostics', () {
      const diagnostics = '''
Analyzing app...
   info • Constructors for public widgets should have a named 'key' parameter • lib/main.dart:4:3 • use_key_in_widget_constructors
   info • Invalid use of a private type in a public API • lib/main.dart:14:3 • library_private_types_in_public_api
3 issues found. (ran in 1.0s)
''';

      final step =
          WorkshopPrivateBuildFailureClassifier.inferStepFromDiagnostics(
        diagnostics,
      );

      expect(step, 'Validate generated project');
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(step),
        'remote_validation_failed',
      );
    });

    test('keeps unknown logs infrastructural', () {
      const diagnostics = 'Runner lost contact with the server.';

      expect(
        WorkshopPrivateBuildFailureClassifier.inferStepFromDiagnostics(
          diagnostics,
        ),
        isNull,
      );
      expect(
        WorkshopPrivateBuildFailureClassifier.codeForStep(null),
        'remote_infrastructure_failed',
      );
    });

    test('keeps toolchain and security failures infrastructural', () {
      for (final step in <String?>[
        'Validate dispatch inputs',
        'Checkout staged Cantiere source only',
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
