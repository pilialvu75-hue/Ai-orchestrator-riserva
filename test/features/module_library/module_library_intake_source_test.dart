import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_library_intake_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('shows real TESTED intake manifest without promoting it to certified', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/git/trees/main')) {
        return http.Response(jsonEncode({
          'truncated': false,
          'tree': [
            {'path': 'intake/utility.cli_arguments.external.dartlang.args/0.1.0/manifest.json'},
            {'path': 'modules/diagnostics.logging/0.1.0/manifest.json'},
          ],
        }), 200);
      }
      if (request.url.path.contains('/contents/intake/')) {
        final manifest = jsonEncode({
          'id': 'utility.cli_arguments.external.dartlang.args',
          'name': 'Dart args',
          'status': 'tested',
        });
        return http.Response(jsonEncode({'content': base64Encode(utf8.encode(manifest))}), 200);
      }
      return http.Response('not found', 404);
    });
    final entries = await ModuleLibraryIntakeSource(client: client).load(token: 'test');
    expect(entries, hasLength(1));
    expect(entries.single.status, 'tested');
    expect(entries.single.id, 'utility.cli_arguments.external.dartlang.args');
  });

  test('rejects truncated GitHub tree rather than showing misleading count', () async {
    final client = MockClient((request) async =>
      http.Response(jsonEncode({'truncated': true, 'tree': []}), 200));
    await expectLater(
      ModuleLibraryIntakeSource(client: client).load(token: 'test'),
      throwsFormatException,
    );
  });

  test('rejects manifest retrieval failures rather than silently dropping modules', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/git/trees/main')) {
        return http.Response(jsonEncode({
          'truncated': false,
          'tree': [{'path': 'intake/example/0.1.0/manifest.json'}],
        }), 200);
      }
      return http.Response('unavailable', 503);
    });
    await expectLater(
      ModuleLibraryIntakeSource(client: client).load(token: 'test'),
      throwsStateError,
    );
  });
}
