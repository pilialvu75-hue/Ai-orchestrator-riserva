import 'workshop_library_github_auth.dart';

typedef WorkshopGitHubClientIdProvider = Future<String?> Function();

/// Resolves the user-authorized GitHub session already stored by
/// AI-Orchestrator, refreshing it when possible.
///
/// The token is never exposed to model prompts or project files. Consumers are
/// responsible for using it only against repositories/capabilities that the
/// user has already authorized through the GitHub App installation.
final class WorkshopGitHubUserTokenProvider {
  WorkshopGitHubUserTokenProvider({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    WorkshopLibraryGitHubAuthClient? authClient,
    required WorkshopGitHubClientIdProvider clientIdProvider,
  })  : _credentialStore =
            credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _authClient = authClient ?? WorkshopLibraryGitHubAuthClient(),
        _clientIdProvider = clientIdProvider;

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final WorkshopLibraryGitHubAuthClient _authClient;
  final WorkshopGitHubClientIdProvider _clientIdProvider;

  Future<String> call() async {
    var credential = await _credentialStore.load();
    if (credential == null) {
      throw StateError(
        'Autorizzazione GitHub assente. Connetti prima la Module Library.',
      );
    }

    if (!credential.isExpired) {
      final token = credential.accessToken.trim();
      if (token.isEmpty) {
        throw StateError('Autorizzazione GitHub non valida.');
      }
      return token;
    }

    final refreshToken = credential.refreshToken?.trim();
    final clientId = (await _clientIdProvider())?.trim();
    if (refreshToken == null ||
        refreshToken.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      throw StateError(
        'Autorizzazione GitHub scaduta. Riconnetti la Module Library.',
      );
    }

    try {
      credential = await _authClient.refresh(
        clientId: clientId,
        refreshToken: refreshToken,
      );
      await _credentialStore.save(credential);
      return credential.accessToken;
    } catch (_) {
      throw StateError(
        'Autorizzazione GitHub scaduta. Riconnetti la Module Library.',
      );
    }
  }
}
