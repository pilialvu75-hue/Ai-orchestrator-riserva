import 'dart:convert';

import 'package:ai_orchestrator/core/memory/fabric/airlab_http_memory_fabric_provider.dart';
import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('write uses private AIrLab Memory API and bearer auth', () async {
    final record = _record(id: 'remote-1');
    final paths = <String>[];

    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      authToken: 'secret-token',
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.method, 'POST');
        expect(request.headers['authorization'], 'Bearer secret-token');
        expect(request.headers['content-type'], contains('application/json'));

        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['id'], record.id);
        expect(payload['privacy_level'], 'project');

        return http.Response(
          jsonEncode(<String, Object?>{'record': record.toJson()}),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final stored = await provider.write(record);

    expect(paths, <String>['/v1/memory/write']);
    expect(stored.id, record.id);
    expect(stored.checksum, record.checksum);
    expect(stored.checksumValid, isTrue);
  });

  test('device-only and secret never reach the remote transport', () async {
    var calls = 0;
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      }),
    );

    for (final privacy in <MemoryFabricPrivacyLevel>[
      MemoryFabricPrivacyLevel.deviceOnly,
      MemoryFabricPrivacyLevel.secret,
    ]) {
      await expectLater(
        provider.write(_record(id: 'private-${privacy.name}', privacy: privacy)),
        throwsA(isA<MemoryFabricRemotePrivacyException>()),
      );
    }

    expect(calls, 0);
  });

  test('invalid local checksum fails before network', () async {
    var calls = 0;
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      }),
    );
    final valid = _record(id: 'tampered-1');
    final tampered = MemoryFabricRecord.fromJson(<String, Object?>{
      ...valid.toJson(),
      'content': 'tampered',
      'checksum': valid.checksum,
    });

    await expectLater(
      provider.write(tampered),
      throwsA(isA<FormatException>()),
    );
    expect(calls, 0);
  });

  test('read maps remote 404 to null', () async {
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test/'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/memory/read');
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'memory_not_found'}),
          404,
        );
      }),
    );

    expect(await provider.read('missing-record'), isNull);
  });

  test('read rejects corrupt or forbidden remote records', () async {
    final valid = _record(id: 'remote-corrupt');

    final corruptProvider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        final payload = <String, Object?>{
          ...valid.toJson(),
          'content': 'corrupted-in-transit',
          'checksum': valid.checksum,
        };
        return http.Response(
          jsonEncode(<String, Object?>{'record': payload}),
          200,
        );
      }),
    );
    await expectLater(
      corruptProvider.read(valid.id),
      throwsA(isA<FormatException>()),
    );

    final deviceOnly = _record(
      id: 'remote-private',
      privacy: MemoryFabricPrivacyLevel.deviceOnly,
    );
    final forbiddenProvider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'record': deviceOnly.toJson()}),
          200,
        );
      }),
    );
    await expectLater(
      forbiddenProvider.read(deviceOnly.id),
      throwsA(isA<MemoryFabricRemotePrivacyException>()),
    );
  });

  test('search serializes all canonical scope and time filters', () async {
    final record = _record(id: 'search-1');
    late Map<String, dynamic> requestPayload;

    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/memory/search');
        requestPayload =
            jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'records': <Map<String, Object?>>[record.toJson()],
          }),
          200,
        );
      }),
    );

    final results = await provider.search(
      MemoryFabricQuery(
        namespace: 'airlab.project',
        types: const <MemoryFabricType>[MemoryFabricType.project],
        text: 'blocked',
        subject: 'project_state',
        tags: const <String>['project', 'cantiere'],
        projectId: 'project-1',
        userId: 'user-1',
        agentId: 'agent-1',
        conversationId: 'conversation-1',
        updatedAfter: DateTime.utc(2026, 9, 22, 8),
        updatedBefore: DateTime.utc(2026, 9, 22, 9),
        includeExpired: false,
        limit: 12,
      ),
    );

    expect(results.single.id, record.id);
    expect(requestPayload['namespace'], 'airlab.project');
    expect(requestPayload['types'], <String>['project']);
    expect(requestPayload['text'], 'blocked');
    expect(requestPayload['subject'], 'project_state');
    expect(requestPayload['tags'], <String>['project', 'cantiere']);
    expect(requestPayload['project_id'], 'project-1');
    expect(requestPayload['user_id'], 'user-1');
    expect(requestPayload['agent_id'], 'agent-1');
    expect(requestPayload['conversation_id'], 'conversation-1');
    expect(requestPayload['limit'], 12);
    expect(requestPayload['include_expired'], isFalse);
  });

  test('health aggregates remote provider degradation', () async {
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/memory/health');
        return http.Response(
          jsonEncode(<String, Object?>{
            'providers': <Map<String, Object?>>[
              <String, Object?>{
                'provider_id': 'supabase',
                'status': 'healthy',
                'readable': true,
                'writable': true,
              },
              <String, Object?>{
                'provider_id': 'nas',
                'status': 'unavailable',
                'readable': false,
                'writable': false,
              },
            ],
          }),
          200,
        );
      }),
    );

    final health = await provider.health();

    expect(health.status, MemoryFabricHealthStatus.degraded);
    expect(health.readable, isTrue);
    expect(health.writable, isTrue);
    expect(
      health.details['remote_providers'],
      isA<List<Map<String, Object?>>>(),
    );
  });

  test('health fails closed when AIrLab Memory is unavailable', () async {
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'memory_fabric_unavailable',
          }),
          503,
        );
      }),
    );

    final health = await provider.health();

    expect(health.status, MemoryFabricHealthStatus.unavailable);
    expect(health.readable, isFalse);
    expect(health.writable, isFalse);
    expect(health.details['error'], isNotNull);
  });

  test('sync aggregates remote reports and preserves conflicts', () async {
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/memory/sync');
        return http.Response(
          jsonEncode(<String, Object?>{
            'reports': <Map<String, Object?>>[
              <String, Object?>{
                'provider_id': 'supabase',
                'ok': true,
                'pulled': 2,
                'pushed': 3,
                'conflicts': 0,
              },
              <String, Object?>{
                'provider_id': 'nas',
                'ok': false,
                'pulled': 1,
                'pushed': 0,
                'conflicts': 2,
              },
            ],
          }),
          200,
        );
      }),
    );

    final report = await provider.sync();

    expect(report.ok, isFalse);
    expect(report.pulled, 3);
    expect(report.pushed, 3);
    expect(report.conflicts, 2);
  });

  test('transport descriptor never advertises local-only privacy', () {
    final provider = AirLabHttpMemoryFabricProvider(
      baseUri: Uri.parse('https://airlab.example.test'),
      httpClient: MockClient((request) async => http.Response('{}', 200)),
    );

    expect(provider.descriptor.location, 'cloud');
    expect(
      provider.descriptor.allowedPrivacy,
      <MemoryFabricPrivacyLevel>{
        MemoryFabricPrivacyLevel.public,
        MemoryFabricPrivacyLevel.project,
        MemoryFabricPrivacyLevel.private,
      },
    );
  });
}

MemoryFabricRecord _record({
  required String id,
  MemoryFabricPrivacyLevel privacy = MemoryFabricPrivacyLevel.project,
}) {
  return MemoryFabricRecord.create(
    id: id,
    namespace: 'airlab.project',
    type: MemoryFabricType.project,
    subject: 'project_state',
    content: 'status=blocked',
    source: 'cantiere_project_state',
    structuredData: const <String, Object?>{
      'next_step': 'repair build',
    },
    now: DateTime.utc(2026, 9, 22, 8),
    privacyLevel: privacy,
    tags: const <String>['project', 'cantiere'],
    projectId: 'project-1',
    userId: 'user-1',
    agentId: 'agent-1',
    conversationId: 'conversation-1',
  );
}
