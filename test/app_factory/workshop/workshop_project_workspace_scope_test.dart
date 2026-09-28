import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_project_workspace_scope.dart';

void main() {
  group('WorkshopProjectWorkspaceScope', () {
    test('different project ids resolve to different stable directories', () {
      final alpha = WorkshopProjectWorkspaceScope.resolve(
        workspaceRootPath: '/tmp/cantiere',
        projectId: 'project:alpha',
      );
      final beta = WorkshopProjectWorkspaceScope.resolve(
        workspaceRootPath: '/tmp/cantiere',
        projectId: 'project:beta',
      );

      expect(alpha, isNot(beta));
      expect(
        WorkshopProjectWorkspaceScope.resolve(
          workspaceRootPath: '/tmp/cantiere',
          projectId: 'project:alpha',
        ),
        alpha,
      );
      expect(alpha, contains('projects'));
    });

    test('project id cannot inject traversal into physical path', () {
      final path = WorkshopProjectWorkspaceScope.resolve(
        workspaceRootPath: '/tmp/cantiere',
        projectId: r'project:../../walking/app',
      );

      final suffix = path.split('/').last;
      expect(suffix, startsWith('project-'));
      expect(suffix, isNot(contains('..')));
      expect(suffix, isNot(contains(':')));
      expect(suffix, isNot(contains(r'\')));
    });

    test('rejects empty root or project id', () {
      expect(
        () => WorkshopProjectWorkspaceScope.resolve(
          workspaceRootPath: ' ',
          projectId: 'project:one',
        ),
        throwsArgumentError,
      );
      expect(
        () => WorkshopProjectWorkspaceScope.resolve(
          workspaceRootPath: '/tmp/cantiere',
          projectId: ' ',
        ),
        throwsArgumentError,
      );
    });
  });
}
