import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_private_github_build_provider.dart';

void main() {
  group('WorkshopGeneratedAppIdentity', () {
    test('is stable for repeated builds of the same project', () {
      final first = WorkshopGeneratedAppIdentity.projectNameFor(
        'project:dashboard:123456',
      );
      final second = WorkshopGeneratedAppIdentity.projectNameFor(
        'project:dashboard:123456',
      );

      expect(first, second);
      expect(first, matches(RegExp(r'^[a-z][a-z0-9_]{0,49}$')));
    });

    test('differs across Cantiere projects', () {
      final first = WorkshopGeneratedAppIdentity.projectNameFor(
        'project:dashboard:123456',
      );
      final second = WorkshopGeneratedAppIdentity.projectNameFor(
        'project:dashboard:999999',
      );

      expect(first, isNot(second));
    });

    test('builds a valid unique Android application id', () {
      final projectName = WorkshopGeneratedAppIdentity.projectNameFor(
        'project:dashboard:123456',
      );
      final applicationId = WorkshopGeneratedAppIdentity.applicationIdFor(
        'project:dashboard:123456',
      );

      expect(
        applicationId,
        'ai.orchestrator.generated.$projectName',
      );
    });

    test('normalizes a human display name without changing project identity', () {
      expect(
        WorkshopGeneratedAppIdentity.displayNameFor(
          '  Manga   Kids\nStudio  ',
        ),
        'Manga Kids Studio',
      );
      expect(
        WorkshopGeneratedAppIdentity.displayNameFor('   '),
        'Cantiere App',
      );
    });

    test('rejects an empty project id', () {
      expect(
        () => WorkshopGeneratedAppIdentity.projectNameFor('   '),
        throwsArgumentError,
      );
    });
  });
}
