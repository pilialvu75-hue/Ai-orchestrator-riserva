import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_stella_queue_dispatcher.dart';

class _Client implements WorkshopGitHubHttpClient {
  Uri? uri;
  Object? body;
  Map<String, String>? headers;
  int statusCode = 204;

  @override
  Future<WorkshopGitHubHttpResponse> get(Uri uri, {Map<String, String>? headers}) async =>
      const WorkshopGitHubHttpResponse(statusCode: 200);

  @override
  Future<WorkshopGitHubHttpResponse> post(Uri uri, {Map<String, String>? headers, Object? body}) async {
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    return WorkshopGitHubHttpResponse(statusCode: statusCode);
  }
}

void main() {
  test('dispatches real workflow input through existing HTTP adapter', () async {
    final client = _Client();
    final dispatcher = WorkshopStellaQueueDispatcher(client: client, accessToken: 'test-token');
    expect(await dispatcher.dispatch(<int>[7, -2, 11]), isTrue);
    expect(client.uri!.path, contains('cantiere-stella-queue.yml/dispatches'));
    expect(client.body, <String, Object>{
      'ref': 'main',
      'inputs': <String, String>{'values': '7,-2,11'},
    });
    expect(client.headers!['Authorization'], 'Bearer test-token');
  });

  test('rejects empty input without dispatch', () async {
    final client = _Client();
    final dispatcher = WorkshopStellaQueueDispatcher(client: client, accessToken: 'test-token');
    await expectLater(dispatcher.dispatch(<int>[]), throwsArgumentError);
    expect(client.uri, isNull);
  });

  test('does not claim success for failed GitHub dispatch', () async {
    final client = _Client()..statusCode = 403;
    final dispatcher = WorkshopStellaQueueDispatcher(client: client, accessToken: 'test-token');
    expect(await dispatcher.dispatch(<int>[1]), isFalse);
  });
}
