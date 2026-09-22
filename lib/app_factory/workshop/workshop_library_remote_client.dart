import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_github_auth.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_package_reader.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_snapshot.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_module_assembly_plan.dart';
import 'package:http/http.dart' as http;

final class WorkshopLibraryRemoteState {
  const WorkshopLibraryRemoteState({
    required this.snapshot,
    required this.packageIndex,
  });

  final WorkshopLibrarySnapshot snapshot;
  final Map<String, WorkshopLibraryPackageIndexEntry> packageIndex;
}

final class WorkshopLibraryPackageIndexEntry {
  const WorkshopLibraryPackageIndexEntry({
    required this.pin,
    required this.path,
    required this.packageSha256,
    required this.moduleTreeSha256,
  });

  final String pin;
  final String path;
  final String packageSha256;
  final String moduleTreeSha256;
}

/// Authenticated, read-only client for the private Module Library consumption
/// exports. It verifies the deterministic snapshot and exact package envelope
/// before returning any reusable file to the Cantiere.
final class WorkshopLibraryRemoteClient {
  WorkshopLibraryRemoteClient({
    WorkshopLibraryGitHubCredentialStore? credentialStore,
    http.Client? client,
    this.repository = 'pilialvu75-hue/AI-Orchestrator-Module-Library',
  })  : _credentialStore =
            credentialStore ?? WorkshopLibraryGitHubCredentialStore(),
        _client = client ?? http.Client();

  static const int _maxPackageBytes = 24 * 1024 * 1024;
  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  final WorkshopLibraryGitHubCredentialStore _credentialStore;
  final http.Client _client;
  final String repository;

  Future<WorkshopLibraryRemoteState> loadState() async {
    _validateRepository();
    final credential = await _credential();
    final snapshotJson = await _readRepoText(
      'catalog/offline-snapshot.json',
      credential.accessToken,
      maxBytes: _maxPackageBytes,
    );
    final snapshotObject = jsonDecode(snapshotJson);
    if (snapshotObject is! Map) {
      throw const FormatException('Library offline snapshot is not an object.');
    }
    final expectedSnapshotSha =
        snapshotObject['snapshot_sha256']?.toString().trim().toLowerCase() ?? '';
    if (!_sha256.hasMatch(expectedSnapshotSha)) {
      throw const FormatException('Library snapshot transport digest is invalid.');
    }
    final snapshot = const WorkshopLibrarySnapshotReader().decode(
      snapshotJson: snapshotJson,
      expectedSnapshotSha256: expectedSnapshotSha,
    );

    final indexJson = await _readRepoText(
      'packages/index.json',
      credential.accessToken,
      maxBytes: 2 * 1024 * 1024,
    );
    final packageIndex = _decodePackageIndex(
      indexJson,
      expectedSnapshotSha: snapshot.snapshotSha256,
    );
    return WorkshopLibraryRemoteState(
      snapshot: snapshot,
      packageIndex: packageIndex,
    );
  }

  Future<WorkshopReusableModulePackage> loadPackage({
    required WorkshopLibraryRemoteState state,
    required String pin,
  }) async {
    final normalizedPin = pin.trim();
    final asset = state.snapshot.assetByPin(normalizedPin);
    if (asset == null) {
      throw StateError(
        'Selected Library package is absent from verified snapshot: $normalizedPin.',
      );
    }
    final indexEntry = state.packageIndex[normalizedPin];
    if (indexEntry == null) {
      throw StateError(
        'Selected Library package has no verified export: $normalizedPin.',
      );
    }
    if (indexEntry.moduleTreeSha256 != asset.moduleTreeSha256) {
      throw const FormatException(
        'Library package index tree digest differs from resolver snapshot.',
      );
    }

    final credential = await _credential();
    final envelopeJson = await _readRepoText(
      indexEntry.path,
      credential.accessToken,
      maxBytes: _maxPackageBytes,
    );
    return const WorkshopLibraryPackageReader().decode(
      envelopeJson: envelopeJson,
      expectedPin: normalizedPin,
      expectedPackageSha256: indexEntry.packageSha256,
      expectedManifestSha256: asset.manifestSha256,
      expectedModuleTreeSha256: asset.moduleTreeSha256,
    );
  }

  Future<WorkshopGitHubUserCredential> _credential() async {
    final credential = await _credentialStore.load();
    if (credential == null || credential.isExpired) {
      throw StateError(
        'Module Library GitHub authorization is missing or expired.',
      );
    }
    return credential;
  }

  Map<String, WorkshopLibraryPackageIndexEntry> _decodePackageIndex(
    String encoded, {
    required String expectedSnapshotSha,
  }) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map ||
        decoded['schema'] != 'ai-orchestrator.library-package-index.v1') {
      throw const FormatException('Unsupported Library package index schema.');
    }
    final snapshotSha =
        decoded['snapshot_sha256']?.toString().trim().toLowerCase() ?? '';
    if (snapshotSha != expectedSnapshotSha) {
      throw const FormatException(
        'Library package index does not belong to verified snapshot.',
      );
    }
    final rawPackages = decoded['packages'];
    if (rawPackages is! List) {
      throw const FormatException('Library package index entries are invalid.');
    }
    final result = <String, WorkshopLibraryPackageIndexEntry>{};
    for (final raw in rawPackages) {
      if (raw is! Map) {
        throw const FormatException('Library package index entry is invalid.');
      }
      final pin = raw['pin']?.toString().trim() ?? '';
      final path = raw['path']?.toString().trim() ?? '';
      final packageSha =
          raw['package_sha256']?.toString().trim().toLowerCase() ?? '';
      final treeSha =
          raw['module_tree_sha256']?.toString().trim().toLowerCase() ?? '';
      if (pin.isEmpty ||
          !_safePath(path) ||
          !_sha256.hasMatch(packageSha) ||
          !_sha256.hasMatch(treeSha) ||
          result.containsKey(pin)) {
        throw const FormatException('Library package index entry is unsafe.');
      }
      result[pin] = WorkshopLibraryPackageIndexEntry(
        pin: pin,
        path: path,
        packageSha256: packageSha,
        moduleTreeSha256: treeSha,
      );
    }
    return Map<String, WorkshopLibraryPackageIndexEntry>.unmodifiable(result);
  }

  Future<String> _readRepoText(
    String path,
    String token, {
    required int maxBytes,
  }) async {
    if (!_safePath(path)) {
      throw const FormatException('Unsafe Module Library repository path.');
    }
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final metadataUri = Uri.parse(
      'https://api.github.com/repos/$repository/contents/$encodedPath?ref=main',
    );
    final metadataResponse = await _get(metadataUri, token);
    if (metadataResponse.statusCode < 200 || metadataResponse.statusCode >= 300) {
      throw StateError(
        'Module Library read failed for $path '
        '(HTTP ${metadataResponse.statusCode}).',
      );
    }
    final metadata = jsonDecode(metadataResponse.body);
    if (metadata is! Map) {
      throw const FormatException('Invalid Module Library content metadata.');
    }

    final size = metadata['size'];
    if (size is int && (size < 0 || size > maxBytes)) {
      throw StateError('Module Library file exceeds allowed transport size.');
    }

    final inline = metadata['content']?.toString().replaceAll('\n', '') ?? '';
    if (inline.isNotEmpty) {
      final bytes = base64Decode(inline);
      if (bytes.length > maxBytes) {
        throw StateError('Module Library file exceeds allowed transport size.');
      }
      return utf8.decode(bytes);
    }

    final sha = metadata['sha']?.toString().trim() ?? '';
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(sha)) {
      throw const FormatException('Module Library blob SHA is missing or invalid.');
    }
    final blobUri = Uri.parse(
      'https://api.github.com/repos/$repository/git/blobs/$sha',
    );
    final blobResponse = await _get(blobUri, token);
    if (blobResponse.statusCode < 200 || blobResponse.statusCode >= 300) {
      throw StateError(
        'Module Library blob read failed (HTTP ${blobResponse.statusCode}).',
      );
    }
    final blob = jsonDecode(blobResponse.body);
    if (blob is! Map || blob['encoding'] != 'base64') {
      throw const FormatException('Module Library blob encoding is invalid.');
    }
    final encoded = blob['content']?.toString().replaceAll('\n', '') ?? '';
    final bytes = base64Decode(encoded);
    if (bytes.length > maxBytes) {
      throw StateError('Module Library blob exceeds allowed transport size.');
    }
    return utf8.decode(bytes);
  }

  Future<http.Response> _get(Uri uri, String token) {
    if (uri.scheme != 'https' || uri.host != 'api.github.com') {
      throw StateError('Refusing non-GitHub Module Library endpoint.');
    }
    return _client.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-workshop-library-reader/1',
      },
    );
  }

  void _validateRepository() {
    if (repository != 'pilialvu75-hue/AI-Orchestrator-Module-Library') {
      throw StateError(
        'Workshop Library reader is locked to the canonical private Library.',
      );
    }
  }

  static bool _safePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.startsWith('~') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.contains('\u0000')) {
      return false;
    }
    return !path.split('/').any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        );
  }
}
