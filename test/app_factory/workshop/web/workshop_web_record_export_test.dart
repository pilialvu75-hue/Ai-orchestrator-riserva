import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_record_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final endpoint = Uri.parse(
      'https://aivexus.example/api/cantiere/proposals/export-records?generationId=fixture');

  http.Response page(List<int> values, Map<String, String>? next) =>
      http.Response(
          jsonEncode({
            'version': 1,
            'ok': true,
            'generationId': 'fixture',
            'collections': [],
            'records': values,
            'next': next,
          }),
          200);

  const cursor = {'afterCollection': 'expenses', 'afterRecordId': 'last'};

  test('collects both pages into one complete download', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return requests.length == 1
          ? page(List.generate(50, (i) => i), cursor)
          : page([50], null);
    });
    final bytes =
        await collectWorkshopRecordExport(client, endpoint, 'fixture');
    expect(requests, [
      endpoint,
      endpoint.replace(queryParameters: {'generationId': 'fixture', ...cursor}),
    ]);
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(data['records'], List.generate(51, (i) => i));
    expect(data['next'], isNull);
  });

  test('rejects a failed second page and a cursor loop', () async {
    final failure = MockClient((request) async =>
        request.url == endpoint ? page([1], cursor) : http.Response('', 503));
    final loop = MockClient((_) async => page([1], cursor));
    for (final client in [failure, loop]) {
      await expectLater(
        collectWorkshopRecordExport(client, endpoint, 'fixture'),
        throwsFormatException,
      );
    }
  });
}
