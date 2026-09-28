import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_lab_github_actions_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('dispatches the Researcher workflow on main', () async {
    var dispatched = false;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(jsonEncode(<String, Object?>{'workflow_runs': <Object?>[
          <String, Object?>{'id': 10, 'status': 'completed', 'conclusion': 'success', 'created_at': '2026-09-28T12:00:00Z'},
        ]}), 200);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/actions/workflows/autonomous-seeding.yml/dispatches')) {
        dispatched = true;
        expect(jsonDecode(request.body), <String, Object?>{'ref': 'main'});
        return http.Response('', 204);
      }
      return http.Response('unexpected', 500);
    });
    final source = ModuleLabGitHubActionsSource(
      credentialStore: throw UnimplementedError(),
      client: client,
      accessTokenProvider: () async => 'test-token',
    );
    await source.dispatchResearcher();
    expect(dispatched, isTrue);
  });

  test('refuses a second Researcher run while one is active', () async {
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') posts += 1;
      return http.Response(jsonEncode(<String, Object?>{'workflow_runs': <Object?>[
        <String, Object?>{'id': 11, 'status': 'in_progress', 'conclusion': null, 'created_at': '2026-09-28T12:00:00Z'},
      ]}), 200);
    });
    final source = ModuleLabGitHubActionsSource(
      credentialStore: throw UnimplementedError(),
      client: client,
      accessTokenProvider: () async => 'test-token',
    );
    await expectLater(source.dispatchResearcher(), throwsA(isA<StateError>()));
    expect(posts, 0);
  });
}
