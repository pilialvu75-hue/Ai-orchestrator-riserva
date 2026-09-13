import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

final class WorkshopLibraryGitHubSubmissionReceipt {
  const WorkshopLibraryGitHubSubmissionReceipt({
    required this.repository,
    required this.branch,
    required this.alreadyOnMain,
    this.pullRequestNumber,
    this.pullRequestUrl,
  });

  final String repository;
  final String branch;
  final bool alreadyOnMain;
  final int? pullRequestNumber;
  final Uri? pullRequestUrl;
}

/// Authenticated GitHub writer for one already-verified Library intake bundle.
///
/// It never writes directly to `main`: a deterministic branch is created from
/// current Library main, manifest + canonical payload are materialized there,
/// and a pull request is opened. Existing identical content is reused;
/// divergent content at the same immutable pin fails closed.
final class WorkshopLibraryGitHubTransport {
  WorkshopLibraryGitHubTransport({
    required WorkshopLibraryGitHubCredentialStore credentialStore,
    http.Client? client,
    this.repository = 'pilialvu75-hue/AI-Orchestrator-Module-Library',
    this.baseBranch = 'main',
  })  : _credentialStore = credentialStore,
        _client = client ?? http.Client();

  static const int _maxPayloadBytes = 20 * 1024 * 1024;
  static const int _maxBundleBytes = 24 * 1024 * 1024;

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final http.Client _client;
  final String repository;
  final String baseBranch;

  Uri get _apiRoot => Uri.parse('https://api.github.com/repos/$repository');

  Future<WorkshopLibraryGitHubSubmissionReceipt> submit(
    WorkshopLibraryIntakeBundle bundle,
  ) async {
    _validateRepository();
    _validateBundle(bundle);
    final credential = await _credentialStore.load();
    if (credential == null || credential.isExpired) {
      throw StateError('Module Library GitHub authorization is missing or expired.');
    }

    final manifestBytes = utf8.encode(jsonEncode(bundle.manifest));
    final payloadBytes = utf8.encode(bundle.payloadJson);
    if (payloadBytes.length > _maxPayloadBytes ||
        utf8.encode(bundle.bundleJson).length > _maxBundleBytes) {
      throw StateError('Module Library intake bundle exceeds transport limits.');
    }

    final manifestPath = bundle.manifestPath;
    final slash = manifestPath.lastIndexOf('/');
    if (slash <= 0 || !manifestPath.endsWith('/manifest.json')) {
      throw const FormatException('Invalid Module Library manifest path.');
    }
    final submissionRoot = manifestPath.substring(0, slash);
    final payloadRepoPath = '$submissionRoot/${bundle.payloadPath}';
    if (!_safeRepoPath(manifestPath) ||
        !_safeRepoPath(payloadRepoPath) ||
        !payloadRepoPath.startsWith('$submissionRoot/payload/')) {
      throw const FormatException('Module Library intake paths are unsafe.');
    }

    final token = credential.accessToken;
    final mainManifest = await _content(manifestPath, ref: baseBranch, token: token);
    if (mainManifest != null) {
      final mainPayload = await _content(payloadRepoPath, ref: baseBranch, token: token);
      if (_sameContent(mainManifest, manifestBytes) &&
          mainPayload != null &&
          _sameContent(mainPayload, payloadBytes)) {
        return WorkshopLibraryGitHubSubmissionReceipt(
          repository: repository,
          branch: baseBranch,
          alreadyOnMain: true,
        );
      }
      throw StateError(
        'Module Library immutable intake pin already exists with divergent content.',
      );
    }

    final branch = _branchName(bundle.pin, bundle.bundleSha256);
    final existingBranch = await _branchRef(branch, token: token);
    if (existingBranch == null) {
      final mainRef = await _branchRef(baseBranch, token: token);
      final mainSha = _refSha(mainRef, label: 'Library main');
      await _jsonRequest(
        'POST',
        _apiRoot.resolve('./git/refs'),
        token: token,
        jsonBody: <String, Object?>{
          'ref': 'refs/heads/$branch',
          'sha': mainSha,
        },
      );
    }

    await _putFile(
      path: manifestPath,
      bytes: manifestBytes,
      branch: branch,
      token: token,
      message: 'intake: add ${bundle.pin} manifest',
    );
    await _putFile(
      path: payloadRepoPath,
      bytes: payloadBytes,
      branch: branch,
      token: token,
      message: 'intake: add ${bundle.pin} payload',
    );

    // Read back both files before claiming a successful handoff.
    final verifiedManifest = await _content(manifestPath, ref: branch, token: token);
    final verifiedPayload = await _content(payloadRepoPath, ref: branch, token: token);
    if (verifiedManifest == null ||
        verifiedPayload == null ||
        !_sameContent(verifiedManifest, manifestBytes) ||
        !_sameContent(verifiedPayload, payloadBytes)) {
      throw StateError('Module Library branch content could not be verified.');
    }

    final existingPr = await _findPullRequest(branch, token: token);
    if (existingPr != null) {
      return _receiptFromPr(branch, existingPr);
    }

    final created = await _jsonRequest(
      'POST',
      _apiRoot.resolve('./pulls'),
      token: token,
      jsonBody: <String, Object?>{
        'title': 'intake: ${bundle.pin}',
        'head': branch,
        'base': baseBranch,
        'body': 'Automated Cantiere intake. Status remains discovered. '
            'Bundle SHA-256: ${bundle.bundleSha256}. '
            'Certification remains exclusively owned by Module Library gates.',
        'maintainer_can_modify': true,
      },
    );
    return _receiptFromPr(branch, created);
  }

  Future<void> _putFile({
    required String path,
    required List<int> bytes,
    required String branch,
    required String token,
    required String message,
  }) async {
    final existing = await _content(path, ref: branch, token: token);
    if (existing != null) {
      if (_sameContent(existing, bytes)) return;
      throw StateError('Module Library branch contains divergent immutable content at $path.');
    }
    await _jsonRequest(
      'PUT',
      _contentsUri(path),
      token: token,
      jsonBody: <String, Object?>{
        'message': message,
        'content': base64Encode(bytes),
        'branch': branch,
      },
    );
  }

  Future<Map<String, dynamic>?> _content(
    String path, {
    required String ref,
    required String token,
  }) =>
      _jsonRequest(
        'GET',
        _contentsUri(path).replace(queryParameters: <String, String>{'ref': ref}),
        token: token,
        missingOk: true,
      );

  Future<Map<String, dynamic>?> _branchRef(
    String branch, {
    required String token,
  }) =>
      _jsonRequest(
        'GET',
        _apiRoot.resolve('./git/ref/heads/${Uri.encodeComponent(branch)}'),
        token: token,
        missingOk: true,
      );

  Future<Map<String, dynamic>?> _findPullRequest(
    String branch, {
    required String token,
  }) async {
    final owner = repository.split('/').first;
    final uri = _apiRoot.resolve('./pulls').replace(
      queryParameters: <String, String>{
        'state': 'all',
        'head': '$owner:$branch',
        'base': baseBranch,
        'per_page': '10',
      },
    );
    final response = await _request('GET', uri, token: token);
    final decoded = _decode(response);
    if (decoded is! List) {
      throw const FormatException('GitHub pull request lookup returned invalid data.');
    }
    for (final item in decoded) {
      if (item is Map) return Map<String, dynamic>.from(item);
    }
    return null;
  }

  Future<Map<String, dynamic>?> _jsonRequest(
    String method,
    Uri uri, {
    required String token,
    Map<String, Object?>? jsonBody,
    bool missingOk = false,
  }) async {
    final response = await _request(
      method,
      uri,
      token: token,
      body: jsonBody == null ? null : jsonEncode(jsonBody),
    );
    if (response.statusCode == 404 && missingOk) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('GitHub Library transport failed with HTTP ${response.statusCode}.');
    }
    final decoded = _decode(response);
    if (decoded is! Map) {
      throw const FormatException('GitHub Library transport expected a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    required String token,
    String? body,
  }) async {
    if (uri.scheme != 'https' || uri.host.toLowerCase() != 'api.github.com') {
      throw const StateError('Refusing non-GitHub API transport endpoint.');
    }
    final request = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
        'User-Agent': 'ai-orchestrator-workshop-library/1',
      });
    if (body != null) request.body = body;
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  Uri _contentsUri(String path) {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    return _apiRoot.resolve('./contents/$encoded');
  }

  static bool _sameContent(Map<String, dynamic> metadata, List<int> expected) {
    final encoded = metadata['content']?.toString().replaceAll('\n', '') ?? '';
    if (encoded.isEmpty) return false;
    try {
      final actual = base64Decode(encoded);
      if (actual.length != expected.length) return false;
      for (var index = 0; index < actual.length; index += 1) {
        if (actual[index] != expected[index]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _refSha(Map<String, dynamic>? ref, {required String label}) {
    final object = ref?['object'];
    if (object is! Map) throw StateError('$label ref is unavailable.');
    final sha = object['sha']?.toString().trim() ?? '';
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(sha)) {
      throw StateError('$label ref SHA is invalid.');
    }
    return sha;
  }

  static WorkshopLibraryGitHubSubmissionReceipt _receiptFromPr(
    String branch,
    Map<String, dynamic> pr,
  ) {
    final number = pr['number'];
    final url = Uri.tryParse(pr['html_url']?.toString() ?? '');
    if (number is! int || url == null || url.scheme != 'https') {
      throw const FormatException('GitHub pull request response is incomplete.');
    }
    return WorkshopLibraryGitHubSubmissionReceipt(
      repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
      branch: branch,
      alreadyOnMain: false,
      pullRequestNumber: number,
      pullRequestUrl: url,
    );
  }

  void _validateRepository() {
    if (repository != 'pilialvu75-hue/AI-Orchestrator-Module-Library' ||
        baseBranch != 'main') {
      throw StateError('Workshop Library transport is locked to the private canonical Library main branch.');
    }
  }

  static void _validateBundle(WorkshopLibraryIntakeBundle bundle) {
    final computed = sha256.convert(utf8.encode(bundle.bundleJson)).toString();
    if (computed != bundle.bundleSha256) {
      throw const FormatException('Module Library bundle SHA-256 mismatch.');
    }
    if (bundle.manifest['status'] != 'discovered') {
      throw const FormatException('Module Library transport accepts discovered intake only.');
    }
  }

  static String _branchName(String pin, String bundleSha) {
    final safePin = pin
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    return 'library-intake/$safePin-${bundleSha.substring(0, 12)}';
  }

  static bool _safeRepoPath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000')) {
      return false;
    }
    final segments = path.split('/');
    return !segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    );
  }

  static Object? _decode(http.Response response) {
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const FormatException('GitHub Library transport returned invalid JSON.');
    }
  }
}
