import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A real, source-bound Module Library package for internal Cantiere tests.
/// No permission to execute in production or install it on Android is implied.
final class ModuleDevelopmentEntry {
  const ModuleDevelopmentEntry({
    required this.pin,
    required this.path,
    required this.packageSha256,
    required this.consumerRunId,
    required this.targets,
  });
  final String pin;
  final String path;
  final String packageSha256;
  final int consumerRunId;
  final List<String> targets;

  String get shortName => pin.split('@').first.replaceFirst(
    'utility.llm_generated.', '',
  );
}

final class ModuleDevelopmentPackage {
  const ModuleDevelopmentPackage({
    required this.entry,
    required this.files,
    required this.capabilities,
    required this.contracts,
  });
  final ModuleDevelopmentEntry entry;
  final Map<String, String> files;
  final List<String> capabilities;
  final List<String> contracts;

  String get sourceSummary => files.entries
      .where((e) => e.key.startsWith('lib/') && e.key.endsWith('.dart'))
      .map((e) => '// ${e.key}\n${e.value}')
      .join('\n\n');
}

/// Separately loads development-qualified (NOT certified) source bundles.
/// Never executes downloaded Dart, writes project files, or changes approvals.
final class ModuleLibraryDevelopmentSource {
  ModuleLibraryDevelopmentSource({http.Client? client})
      : _client = client ?? http.Client();

  static const repository = 'pilialvu75-hue/AI-Orchestrator-Module-Library';
  static const schema = 'aivexus.library.development-qualified-index.v1';
  static const _indexPath = 'packages/development-index.json';
  static final _pin = RegExp(
    r'^utility[.]llm_generated[.][a-z][a-z0-9_]{1,60}@[0-9]+[.][0-9]+[.][0-9]+$',
  );
  static final _sha = RegExp(r'^[0-9a-f]{64}$');

  final http.Client _client;

  Future<List<ModuleDevelopmentEntry>> load({required String token}) async {
    final index = await _fetchJson(_indexPath, token: token);
    if (index['schema'] != schema ||
        index['production_certified'] != false ||
        index['production_approved'] != false ||
        index['policy'] != 'internal-development-only-no-production-or-redistribution') {
      throw const FormatException('Indice dei moduli di sviluppo non valido.');
    }
    final raw = index['packages'];
    if (raw is! List || raw.length > 250) {
      throw const FormatException('Elenco dei moduli di sviluppo non valido.');
    }
    final seen = <String>{};
    final result = <ModuleDevelopmentEntry>[];
    for (final value in raw) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Voce di sviluppo non valida.');
      }
      final pin = value['pin']?.toString() ?? '';
      final path = value['path']?.toString() ?? '';
      final digest = value['package_sha256']?.toString() ?? '';
      final runId = value['consumer_workflow_run_id'];
      final targets = value['validated_targets'];
      final allowedPath = pin.contains('@')
          ? 'packages/experimental/${pin.replaceFirst('@', '/')}/package.json'
          : '';
      if (!_pin.hasMatch(pin) ||
          !seen.add(pin) ||
          path != allowedPath ||
          !_sha.hasMatch(digest) ||
          runId is! int ||
          runId <= 0 ||
          targets is! List ||
          targets.isEmpty ||
          targets.any((x) => x is! String || x.isEmpty) ||
          value['status'] != 'development_qualified' ||
          value['development_qualified'] != true ||
          value['independent_export_consumer'] != 'PASS' ||
          value['production_certified'] != false ||
          value['production_approved'] != false ||
          value['security_reviewed'] != false ||
          value['license_approved'] != false) {
        throw FormatException('Voce di sviluppo incoerente: $pin.');
      }
      result.add(ModuleDevelopmentEntry(
        pin: pin,
        path: path,
        packageSha256: digest,
        consumerRunId: runId,
        targets: List<String>.unmodifiable(targets.cast<String>()),
      ));
    }
    result.sort((a, b) => a.pin.compareTo(b.pin));
    return List<ModuleDevelopmentEntry>.unmodifiable(result);
  }

  Future<ModuleDevelopmentPackage> loadPackage({
    required String token,
    required ModuleDevelopmentEntry entry,
  }) async {
    if (!_pin.hasMatch(entry.pin) ||
        !_sha.hasMatch(entry.packageSha256) ||
        entry.path !=
            'packages/experimental/${entry.pin.replaceFirst('@', '/')}/package.json') {
      throw const FormatException('Identità del modulo non valida.');
    }
    final envelope = await _fetchJson(entry.path, token: token);
    if (envelope['schema'] !=
        'ai-orchestrator.library-module-package-envelope.v1') {
      throw const FormatException('Formato del pacchetto non valido.');
    }
    final payload = envelope['package'];
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Sorgenti del modulo assenti.');
    }
    final actual = sha256.convert(utf8.encode(jsonEncode(_ordered(payload)))).toString();
    if (actual != entry.packageSha256 ||
        envelope['package_sha256'] != actual ||
        payload['pin'] != entry.pin ||
        payload['tier'] != 'sandbox_preview' ||
        payload['status'] != 'tested' ||
        payload['certified'] != false ||
        payload['availability'] != 'experimental' ||
        payload['usage_policy'] != 'internal-isolated-evaluation-only') {
      throw const FormatException('SHA256 o stato del pacchetto non validi.');
    }
    final review = payload['review'];
    if (review is! Map ||
        review['security_reviewed'] != false ||
        review['production_approved'] != false ||
        review['license_verified'] != false) {
      throw const FormatException('Il modulo non rispetta lo stato sperimentale.');
    }
    final rawFiles = payload['files'];
    if (rawFiles is! List || rawFiles.isEmpty || rawFiles.length > 50) {
      throw const FormatException('Allegati del modulo non validi.');
    }
    final files = <String, String>{};
    var total = 0;
    for (final item in rawFiles) {
      if (item is! Map) {
        throw const FormatException('File del modulo non valido.');
      }
      final path = item['target_path']?.toString() ?? '';
      final contents = item['content'];
      if (!_safePath(path) || contents is! String || files.containsKey(path)) {
        throw const FormatException('Percorso o contenuto del modulo non sicuro.');
      }
      total += utf8.encode(contents).length;
      if (total > 2 * 1024 * 1024) {
        throw const FormatException('Il modulo supera il limite dimensionale.');
      }
      files[path] = contents;
    }
    if (!files.keys.any((p) => p.startsWith('lib/') && p.endsWith('.dart')) ||
        !files.containsKey('pubspec.yaml')) {
      throw const FormatException('Il modulo non contiene codice Dart.');
    }
    final capabilities = payload['capabilities'];
    final contracts = payload['contracts'];
    if (capabilities is! List ||
        contracts is! List ||
        capabilities.isEmpty ||
        contracts.isEmpty ||
        capabilities.any((x) => x is! String) ||
        contracts.any((x) => x is! String)) {
      throw const FormatException('Contratti del modulo non validi.');
    }
    return ModuleDevelopmentPackage(
      entry: entry,
      files: Map<String, String>.unmodifiable(files),
      capabilities: List<String>.unmodifiable(capabilities.cast<String>()),
      contracts: List<String>.unmodifiable(contracts.cast<String>()),
    );
  }

  Future<Map<String, dynamic>> _fetchJson(
    String path, {
    required String token,
  }) async {
    if (!_safePath(path) || token.trim().isEmpty) {
      throw StateError('Credenziale GitHub o percorso del modulo assente.');
    }
    final uri = Uri.https(
      'api.github.com',
      '/repos/$repository/contents/${path.split('/').map(Uri.encodeComponent).join('/')}',
      <String, String>{'ref': 'main'},
    );
    final response = await _client.get(uri, headers: <String, String>{
      'Accept': 'application/vnd.github+json',
      'Authorization': 'Bearer $token',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'aivexus-development-module-reader/1',
    });
    if (response.statusCode != 200) {
      throw StateError('Lettura GitHub del modulo fallita: HTTP ${response.statusCode}.');
    }
    final metadata = jsonDecode(response.body);
    if (metadata is! Map || metadata['encoding'] != 'base64') {
      throw const FormatException('Risposta GitHub non valida.');
    }
    final encoded = metadata['content'];
    if (encoded is! String || encoded.length > 12 * 1024 * 1024) {
      throw const FormatException('Il modulo è assente o troppo grande.');
    }
    final bytes = base64Decode(encoded.replaceAll('\n', ''));
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Il modulo è troppo grande.');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Il modulo non contiene JSON valido.');
    }
    return decoded;
  }

  static Object? _ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _ordered(value[key]),
      };
    }
    if (value is List) return value.map(_ordered).toList(growable: false);
    return value;
  }

  static bool _safePath(String path) =>
      path.isNotEmpty &&
      !path.startsWith('/') &&
      !path.startsWith('~') &&
      !path.contains('\\') &&
      !path.contains(':') &&
      !path.contains('\u0000') &&
      path.split('/').every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}
