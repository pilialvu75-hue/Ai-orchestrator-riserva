import 'dart:convert';

import 'package:http/http.dart' as http;

Future<List<int>> collectWorkshopRecordExport(
  http.Client client,
  Uri endpoint,
  String generationId,
) async {
  var uri = endpoint;
  final records = <Object?>[];
  List<dynamic>? collections;
  String? previousCursor;
  var bytes = 0;
  while (true) {
    final response = await client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const FormatException('Record export unavailable');
    }
    bytes += response.bodyBytes.length;
    if (bytes > 32 * 1024 * 1024) {
      throw const FormatException('Record export exceeds the browser limit');
    }
    final page = jsonDecode(utf8.decode(response.bodyBytes));
    if (page is! Map<String, dynamic> ||
        page['version'] != 1 ||
        page['ok'] != true ||
        page['generationId'] != generationId ||
        page['collections'] is! List ||
        page['records'] is! List ||
        !page.containsKey('next')) {
      throw const FormatException('Invalid export page');
    }
    collections ??= page['collections'] as List;
    records.addAll(page['records'] as List);
    final next = page['next'];
    if (next == null) break;
    if (next is! Map<String, dynamic> ||
        next['afterCollection'] is! String ||
        next['afterRecordId'] is! String) {
      throw const FormatException('Invalid export cursor');
    }
    final collection = next['afterCollection'] as String;
    final recordId = next['afterRecordId'] as String;
    final cursor = '$collection/$recordId';
    if (previousCursor != null && cursor.compareTo(previousCursor) <= 0) {
      throw const FormatException('Export cursor did not advance');
    }
    previousCursor = cursor;
    uri = endpoint.replace(queryParameters: {
      'generationId': generationId,
      'afterCollection': collection,
      'afterRecordId': recordId,
    });
  }
  return utf8.encode(jsonEncode({
    'version': 1,
    'ok': true,
    'generationId': generationId,
    'collections': collections,
    'records': records,
    'next': null,
  }));
}
