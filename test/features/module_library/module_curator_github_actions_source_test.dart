import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_curator_github_actions_source.dart';
import 'package:ai_orchestrator/features/module_library/domain/module_curator_advice.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  List<int> resultZip() {
    final payload = jsonEncode(<String, Object?>{
      'schema': ModuleCuratorResult.schema,
      'provider': 'gemini:gemini-3.6-flash',
      'request': <String, Object?>{},
      'advice': <String, Object?>{
        'schema': 'ai-orchestrator.library-curator-response.v1',
        'request_id': 'request',
        'recommendations': <Object?>[
          <String, Object?>{
            'type': 'coverage_gap',
            'confidence': 1.0,
            'summary': 'Nessun candidato disponibile.',
            'asset_refs': <String>[],
            'capability_ids': <String>['storage.local_db'],
            'adapter_suggestions': <String>[],
            'warnings': <String>[],
            'ranking_factors': <Object?>[],
          },
        ],
      },
      'core_verification': <String, Object?>{
        'passed': true,
        'advisory_only': true,
        'library_mutated': false,
        'authority': 'deterministic-library-core',
        'ai_called': false,
      },
    });
    final bytes = utf8.encode(payload);
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'library-curator-result.json',
          bytes.length,
          bytes,
        ),
      );
    return ZipEncoder().encode(archive)!;
  }

  test('dispatches exact correlated workflow and reads verified artifact', () async {
    final zip = resultZip();
    Map<String, Object?>? dispatchBody;
    var calls = 0;
    final client = MockClient((request) async {
      calls += 1;
      if (request.method == 'POST' &&
          request.url.path.endsWith(
            '/actions/workflows/run-curator-gemini.yml/dispatches',
          )) {
        dispatchBody = Map<String, Object?>.from(
          jsonDecode(request.body) as Map,
        );
        expect(request.headers['authorization'], 'Bearer token-test');
        return http.Response('', 204);
      }
      if (request.url.path.endsWith(
        '/actions/workflows/run-curator-gemini.yml/runs',
      )) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'workflow_runs': <Object?>[
              <String, Object?>{
                'id': 42,
                'display_title':
                    'Curator rank_candidates storage.local_db [mobile-request]',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/actions/runs/42')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'status': 'completed',
            'conclusion': 'success',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/actions/runs/42/artifacts')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'artifacts': <Object?>[
              <String, Object?>{
                'id': 77,
                'name': 'library-curator-gemini-result',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/actions/artifacts/77/zip')) {
        return http.Response.bytes(zip, 200);
      }
      return http.Response('unexpected ${request.method} ${request.url}', 500);
    });

    final source = ModuleCuratorGitHubActionsSource(
      client: client,
      accessTokenProvider: () async => 'token-test',
      requestIdFactory: () => 'mobile-request',
      delay: (_) async {},
    );

    final result = await source.run(
      task: ModuleCuratorTask.rankCandidates,
      capabilityId: 'storage.local_db',
    );

    expect(calls, 5);
    expect(result.provider, 'gemini:gemini-3.6-flash');
    expect(result.hasAdvice, isTrue);
    expect(result.aiCalled, isFalse);
    expect(dispatchBody?['ref'], 'main');
    final inputs = Map<String, Object?>.from(
      dispatchBody?['inputs']! as Map,
    );
    expect(inputs['task'], 'rank_candidates');
    expect(inputs['capability'], 'storage.local_db');
    expect(inputs['client_request_id'], 'mobile-request');
    expect(inputs['model'], 'gemini-3.6-flash');
    expect(jsonEncode(dispatchBody), isNot(contains('GEMINI_API_KEY')));
  });

  test('explains missing Actions permission without exposing credentials', () async {
    final client = MockClient((request) async => http.Response('', 403));
    final source = ModuleCuratorGitHubActionsSource(
      client: client,
      accessTokenProvider: () async => 'secret-token-value',
      requestIdFactory: () => 'mobile-request',
      delay: (_) async {},
    );

    await expectLater(
      source.run(
        task: ModuleCuratorTask.rankCandidates,
        capabilityId: 'storage.local_db',
      ),
      throwsA(
        isA<StateError>()
            .having(
              (error) => error.toString(),
              'message',
              contains('Actions: Read and write'),
            )
            .having(
              (error) => error.toString(),
              'no token leak',
              isNot(contains('secret-token-value')),
            ),
      ),
    );
  });
}
