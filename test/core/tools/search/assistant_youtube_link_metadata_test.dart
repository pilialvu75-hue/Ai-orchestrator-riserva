import 'dart:convert';

import 'package:ai_orchestrator/core/tools/search/assistant_youtube_link_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AssistantYouTubeLink', () {
    test('accepts Shorts, watch, embed and short links without tracking data', () {
      const id = 'hZdi0JUEFSc';
      for (final input in <String>[
        'ecco il link: https://youtube.com/shorts/$id?is=private-tracker',
        'https://www.youtube.com/watch?v=$id&t=9',
        'https://m.youtube.com/watch?v=$id',
        'https://youtu.be/$id?si=something',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/live/$id',
      ]) {
        final result = AssistantYouTubeLink.fromUserMessage(input);
        expect(result?.videoId, id, reason: input);
        expect(result?.canonicalUrl.toString(),
            'https://www.youtube.com/watch?v=$id');
      }
    });

    test('rejects suspicious hosts, credentials and malformed identifiers', () {
      const bad = <String>[
        'https://youtube.com.evil.example/shorts/hZdi0JUEFSc',
        'https://notyoutube.com/watch?v=hZdi0JUEFSc',
        'https://evil.youtube.com/watch?v=hZdi0JUEFSc',
        'https://user@youtube.com/shorts/hZdi0JUEFSc',
        'https://youtube.com:8443/shorts/hZdi0JUEFSc',
        'http://youtube.com/shorts/hZdi0JUEFSc',
        'https://youtube.com/shorts/too-short',
        'https://youtube.com/redirect?url=hZdi0JUEFSc',
        'https://127.0.0.1/watch?v=hZdi0JUEFSc',
        'https://youtube.com/watch?v=hZdi0JUEFSc&v=upY-jceP0vM',
        'https://youtu.be/hZdi0JUEFSc https://youtu.be/upY-jceP0vM',
      ];
      for (final text in bad) {
        expect(AssistantYouTubeLink.fromUserMessage(text), isNull, reason: text);
      }
    });
  });

  group('AssistantYouTubeMetadataService', () {
    const link = AssistantYouTubeLink('hZdi0JUEFSc');

    test('uses only official fixed oEmbed endpoint and canonical video ID', () async {
      late http.Request seen;
      final reader = AssistantYouTubeMetadataService(
        client: MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(<String, String>{
            'title': 'Titolo pubblico',
            'author_name': 'Canale ufficiale',
            'description': 'Not a source for transcripts',
          }), 200);
        }),
      );
      final result = await reader.fetch(link);
      expect(result?.title, 'Titolo pubblico');
      expect(result?.channel, 'Canale ufficiale');
      expect(seen.url.scheme, 'https');
      expect(seen.url.host, 'www.youtube.com');
      expect(seen.url.path, '/oembed');
      expect(seen.url.queryParameters['url'],
          'https://www.youtube.com/watch?v=hZdi0JUEFSc');
      expect(seen.url.toString(), isNot(contains('private-tracker')));
      expect(seen.followRedirects, false);
    });

    test('does not accept missing metadata or invalid responses', () async {
      final empty = AssistantYouTubeMetadataService(
        client: MockClient((_) async => http.Response('{"title":"Hello"}', 200)),
      );
      final httpError = AssistantYouTubeMetadataService(
        client: MockClient((_) async => http.Response('No access', 404)),
      );
      final invalidJson = AssistantYouTubeMetadataService(
        client: MockClient((_) async => http.Response('invalid', 200)),
      );
      expect(await empty.fetch(link), isNull);
      expect(await httpError.fetch(link), isNull);
      expect(await invalidJson.fetch(link), isNull);
    });

    test('rejects oversized payloads and never exposes raw content', () async {
      final reader = AssistantYouTubeMetadataService(
        maxResponseBytes: 64,
        client: MockClient((_) async => http.Response(
            jsonEncode(<String, String>{
              'title': List<String>.filled(100, 'X').join(),
              'author_name': 'Canale',
            }), 200)),
      );
      expect(await reader.fetch(link), isNull);
    });

    test('normalizes control characters in metadata', () async {
      final reader = AssistantYouTubeMetadataService(
        client: MockClient((_) async => http.Response(
            jsonEncode(<String, String>{
              'title': 'Primo\nSecondo',
              'author_name': 'Canale\tvideo',
            }), 200)),
      );
      final result = await reader.fetch(link);
      expect(result?.title, 'Primo Secondo');
      expect(result?.channel, 'Canale video');
    });
  });
}
