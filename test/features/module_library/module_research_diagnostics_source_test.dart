import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_research_diagnostics_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('keeps the newest Researcher capability event across releases', () async {
    Map<String, Object?> event({
      required String timestamp,
      required int candidates,
      required String state,
    }) => <String, Object?>{
          'schema': 'ai-orchestrator.diagnostics.event.v2',
          'producer': 'researcher',
          'producer_version': '1.0.0',
          'platform': 'linux',
          'instance': 'researcher-a',
          'run': 'run-1',
          'timestamp': timestamp,
          'event': 'CAPABILITY_STATUS',
          'severity': 'info',
          'correlation_id': 'capability:voice.stt:$timestamp',
          'fields': <String, Object?>{
            'component': 'capability_status',
            'capability_id': 'voice.stt',
            'research_state': state,
            'candidate_count': candidates,
            'qualified_candidates': 1,
            'shortlisted': 1,
            'submitted': 0,
            'security_review': 0,
            'security_blocked': 0,
          },
        };

    final older = jsonEncode(
      event(
        timestamp: '2026-09-14T00:00:00Z',
        candidates: 1,
        state: 'SEARCHING',
      ),
    );
    final newer = jsonEncode(
      event(
        timestamp: '2026-09-14T00:05:00Z',
        candidates: 3,
        state: 'CANDIDATES_FOUND',
      ),
    );

    final source = GitHubDiagnosticsResearchStatusSource(
      client: MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        return http.Response(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'tag_name': 'diagnostics-researcher-v1-a',
              'body': '# Researcher\n```jsonl\n$older\n$newer\n```\n',
            },
            <String, Object?>{
              'tag_name': 'diagnostics-library-v1-a',
              'body': newer,
            },
          ]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final payload = await source.load();
    expect(payload, isNotNull);
    final rows = payload!['capabilities'] as List<Object?>;
    expect(rows, hasLength(1));
    final row = rows.single as Map<String, Object?>;
    expect(row['capability_id'], 'voice.stt');
    expect(row['research_state'], 'CANDIDATES_FOUND');
    expect(row['candidate_count'], 3);
    expect(row['last_scan'], '2026-09-14T00:05:00.000Z');
  });

  test('returns null when Diagnostics has no Researcher projection', () async {
    final source = GitHubDiagnosticsResearchStatusSource(
      client: MockClient(
        (_) async => http.Response(jsonEncode(<Object?>[]), 200),
      ),
    );

    expect(await source.load(), isNull);
  });
}
