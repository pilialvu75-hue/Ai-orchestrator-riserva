import 'package:ai_orchestrator/app_factory/workshop/workshop_github_build_provider.dart';

/// Starts the experimental Stella Queue generator through the existing
/// authenticated Workshop GitHub HTTP adapter. Never stores a token.
final class WorkshopStellaQueueDispatcher {
  const WorkshopStellaQueueDispatcher({
    required this.client,
    required this.accessToken,
    this.owner = 'pilialvu75-hue',
    this.repository = 'Ai-orchestrator-riserva',
    this.ref = 'main',
  });

  final WorkshopGitHubHttpClient client;
  final String accessToken;
  final String owner;
  final String repository;
  final String ref;

  /// Returns a submitted dispatch, not a completed or certified app.
  Future<bool> dispatch(List<int> values) async {
    if (values.isEmpty || values.length > 100) {
      throw ArgumentError.value(values, 'values', 'Requires 1–100 integers');
    }
    if (accessToken.isEmpty) {
      throw StateError('GitHub authorization is required');
    }
    final uri = Uri.https(
      'api.github.com',
      '/repos/$owner/$repository/actions/workflows/'
          'cantiere-stella-queue.yml/dispatches',
    );
    final response = await client.post(
      uri,
      headers: <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $accessToken',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      },
      body: <String, Object>{
        'ref': ref,
        'inputs': <String, String>{'values': values.join(',')},
      },
    );
    return response.statusCode == 204;
  }
}
