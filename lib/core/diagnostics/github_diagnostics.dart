import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/diagnostics/diagnostics_release_body.dart';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/diagnostics/public_log_projection.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Opt-in public diagnostics. Never uploads the original crash file.
/// Release assets avoid retaining every log revision in Git history.
class GitHubDiagnostics extends ChangeNotifier {
  GitHubDiagnostics._();
  static final instance = GitHubDiagnostics._();
  static const repository = 'pilialvu75-hue/Ai-orchestrator-diagnostics';
  String get tag => 'diagnostics-v1-$installationId';
  String installationId = '';
  String deviceName = '';
  final String sessionId = const Uuid().v4();
  DateTime? lastUpload;
  int get queuedFiles => _directory == null ? 0 : _files().length;
  int get queuedBytes => _directory == null ? 0 : _files().fold<int>(0, (n, f) => n + f.lengthSync());
  String get releaseUrl => 'https://github.com/$repository/releases/tag/$tag';

  Future<void> renameDevice(String name) async {
    await initialize();
    final value = name.trim();
    if (!RegExp(r'^[a-zA-Z0-9 _-]{1,40}$').hasMatch(value)) {
      throw ArgumentError('Usa da 1 a 40 lettere, numeri, spazi o trattini');
    }
    await _prefs!.setString('diagnostics.deviceName', value);
    deviceName = value;
    notifyListeners();
  }
  static const maxBytes = 20 * 1024 * 1024;
  static const chunkBytes = 1024 * 1024;
  static const _key = 'github.diagnostics.token.v1';
  final _secure = const FlutterSecureStorage();
  Directory? _directory;
  SharedPreferences? _prefs;
  Future<void>? _initializing;
  bool enabled = false;
  bool busy = false;
  String status = 'Non configurato';
  String _build = 'unknown';
  final List<String> _pending = [];
  int _pendingBytes = 0;
  DateTime _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  int _failures = 0;
  static const _root = 'https://api.github.com/repos/$repository';

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      enabled = _prefs!.getBool('diagnostics.enabled') ?? false;
      installationId = _prefs!.getString('diagnostics.installationId') ?? const Uuid().v4();
      await _prefs!.setString('diagnostics.installationId', installationId);
      deviceName = _prefs!.getString('diagnostics.deviceName') ?? '${defaultTargetPlatform.name}-${installationId.substring(0, 8)}';
      lastUpload = DateTime.tryParse(_prefs!.getString('diagnostics.lastUpload') ?? '');
      final dir = await getApplicationSupportDirectory();
      _directory = await Directory('${dir.path}/public-diagnostics-v1').create(recursive: true);
      final info = await PackageInfo.fromPlatform();
      // Build metadata is restricted to printable version digits.
      _build = '${info.version}+${info.buildNumber}'.replaceAll(RegExp(r'[^0-9.+-]'), '');
      await _recoverDisk();
      RuntimeEventLog.instance.stream.listen((entry) {
        try {
          if (enabled) _capture(entry.toString());
        } catch (_) {
          // Diagnostic disk failures must never escape into the runtime.
          status = 'Spazio diagnostico locale non disponibile';
        }
      });
      Timer.periodic(const Duration(seconds: 60), (_) => unawaited(sync()));
      status = enabled ? 'Pronto: invio automatico ogni minuto' : 'Disattivato';
    } catch (_) {
      status = 'Archivio diagnostico non disponibile';
    }
    notifyListeners();
  }

  Future<void> configure(String token, bool value) async {
    await initialize();
    if (_directory == null) throw StateError('Archivio non disponibile');
    if (token.trim().isNotEmpty) await _secure.write(key: _key, value: token.trim());
    if (value && (await _secure.read(key: _key) ?? '').isEmpty) {
      throw StateError('Inserisci un token GitHub dedicato');
    }
    await _prefs!.setBool('diagnostics.enabled', value);
    enabled = value;
    if (value) await _recoverDisk();
    status = value ? 'Invio automatico attivato' : 'Invio disattivato';
    notifyListeners();
  }

  void _capture(String raw) {
    final projected = publicLogProjection(raw);
    if (projected == null) return;
    _pending.add(projected);
    _pendingBytes += projected.length + 1; // Projection is ASCII.
    while (_pendingBytes > chunkBytes && _pending.isNotEmpty) {
      _pendingBytes -= _pending.removeAt(0).length + 1;
    }
    if (_pendingBytes >= chunkBytes - 1024) _seal();
  }

  // The original crash sink is the durable source before the next batch seals.
  Future<void> _recoverDisk() async {
    if (!enabled) return;
    final raw = await RuntimeEventLog.instance.readPersistedLog();
    final fingerprint = sha256.convert(utf8.encode(raw)).toString();
    if (_prefs!.getString('diagnostics.recovered') == fingerprint) return;
    for (final line in const LineSplitter().convert(raw)) { _capture(line); }
    _seal();
    await _prefs!.setString('diagnostics.recovered', fingerprint);
  }

  void _seal() {
    if (_pending.isEmpty || _directory == null) return;
    final text = 'schema=1 build=$_build device=$installationId name=$deviceName platform=${defaultTargetPlatform.name} capture_session=$sessionId sources=runtime+android-disk\n${_pending.join('\n')}\n';
    final bytes = utf8.encode(text);
    final hash = sha256.convert(bytes).toString();
    final crash = text.contains('ANDROID_PROCESS_EXIT_HISTORY') || text.contains('FORENSIC_UNCAUGHT_DART_EXCEPTION');
    final file = File('${_directory!.path}/diag-${crash ? 'crash-' : ''}$hash.txt');
    // Atomic rename: a process death must not create a partial upload candidate.
    final temporary = File('${file.path}.tmp');
    temporary.writeAsBytesSync(bytes, flush: true);
    temporary.renameSync(file.path);
    _pending.clear();
    _pendingBytes = 0;
    final files = _files();
    files.sort((a, b) {
      final priority = (a.path.contains('diag-crash-') ? 1 : 0) - (b.path.contains('diag-crash-') ? 1 : 0);
      return priority != 0 ? priority : a.lastModifiedSync().compareTo(b.lastModifiedSync());
    });
    var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    for (final old in files) {
      if (total <= maxBytes) break;
      total -= old.lengthSync();
      old.deleteSync();
    }
  }

  List<File> _files() => _directory!.listSync().whereType<File>()
      .where((f) => f.path.endsWith('.txt')).toList()
    ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));

  Future<dynamic> _request(http.Client client, String token, String method,
      String url, {Object? body, bool missingOk = false, bool binary = false}) async {
    final request = http.Request(method, Uri.parse(url))..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $token', 'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': binary ? 'text/plain; charset=utf-8' : 'application/json',
    });
    if (body != null) {
      request.bodyBytes = binary ? body as List<int> : utf8.encode(jsonEncode(body));
    }
    final response = await (() async => http.Response.fromStream(await client.send(request)))()
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 404 && missingOk) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Never put server bodies/headers (or the token) in logs or UI.
      throw HttpException('GitHub HTTP ${response.statusCode}');
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<void> sync() async {
    await initialize();
    if (!enabled || busy || _directory == null || DateTime.now().isBefore(_nextAttempt)) return;
    busy = true;
    notifyListeners();
    final client = http.Client();
    try {
      _seal();
      final files = _files();
      if (files.isEmpty) { status = 'Nessun nuovo evento da inviare'; return; }
      final token = await _secure.read(key: _key);
      if (token == null || token.isEmpty) throw StateError('Token mancante');
      var release = await _request(client, token, 'GET', '$_root/releases/tags/$tag', missingOk: true);
      if (release == null) {
        release = await _request(client, token, 'POST', '$_root/releases', body: {
          'tag_name': tag, 'name': 'Diagnostica $deviceName',
          'body': 'Log tecnici filtrati. latest.txt: ultima porzione. diag-*.txt: archivio ruotato (20 MiB). Nessun testo di conversazione.',
        });
      }
      final id = release['id'] as int;
      final assets = <Map<String, dynamic>>[];
      for (var page = 1; ; page++) {
        final list = await _request(client, token, 'GET', '$_root/releases/$id/assets?per_page=100&page=$page') as List;
        assets.addAll(list.map((a) => Map<String, dynamic>.from(a as Map)));
        if (list.length < 100) break;
      }
      for (final file in files.take(3)) {
        if (!enabled) break;
        final name = file.uri.pathSegments.last;
        final bytes = await file.readAsBytes();
        final matching = assets.where((a) => a['name'] == name).toList();
        final alreadyUploaded = matching.isNotEmpty && matching.first['state'] == 'uploaded' && matching.first['size'] == bytes.length;
        for (final a in alreadyUploaded ? <Map<String, dynamic>>[] : matching) {
          await _request(client, token, 'DELETE', '$_root/releases/assets/${a['id']}');
          assets.remove(a);
        }
        // Only our owned archive files are eligible for retention deletion.
        final owned = assets.where((a) => RegExp(r'^diag-(crash-)?[a-f0-9]{64}\.txt$').hasMatch('${a['name']}')).toList()
          ..sort((a, b) {
            final priority = ('${a['name']}'.startsWith('diag-crash-') ? 1 : 0) - ('${b['name']}'.startsWith('diag-crash-') ? 1 : 0);
            return priority != 0 ? priority : '${a['created_at']}'.compareTo('${b['created_at']}');
          });
        var total = owned.fold<int>(0, (sum, a) => sum + (a['size'] as int));
        var count = owned.length;
        for (final old in owned) {
          if (total + bytes.length <= maxBytes - 256 * 1024 && count < 99) break;
          if (old['name'] == name) continue;
          await _request(client, token, 'DELETE', '$_root/releases/assets/${old['id']}');
          total -= old['size'] as int;
          count--;
          assets.remove(old);
        }
        if (!alreadyUploaded) {
        final uploaded = await _request(client, token, 'POST',
          'https://uploads.github.com/repos/$repository/releases/$id/assets?name=$name', body: bytes, binary: true);
        assets.add(Map<String, dynamic>.from(uploaded as Map));
        }
        for (final old in assets.where((a) => a['name'] == 'latest.txt').toList()) {
          await _request(client, token, 'DELETE', '$_root/releases/assets/${old['id']}');
          assets.remove(old);
        }
        final start = bytes.length > 250 * 1024 ? bytes.length - 250 * 1024 : 0;
        final newline = start == 0 ? 0 : bytes.indexOf(10, start) + 1;
        final latest = await _request(client, token, 'POST',
          'https://uploads.github.com/repos/$repository/releases/$id/assets?name=latest.txt',
          body: bytes.sublist(newline), binary: true);
        assets.add(Map<String, dynamic>.from(latest as Map));
        // Commit the readable summary before acknowledging the local batch.
        // A failed PATCH keeps the batch queued; retries reuse its archive asset.
        final summary = diagnosticsReleaseBody(utf8.decode(bytes),
          previousBody: release['body'] as String? ?? '');
        release = await _request(client, token, 'PATCH', '$_root/releases/$id', body: {
          'name': 'Diagnostica $deviceName',
          'body': summary,
        });
        await file.delete();
      }
      _failures = 0;
      lastUpload = DateTime.now();
      await _prefs!.setString('diagnostics.lastUpload', lastUpload!.toIso8601String());
      status = 'Caricamento riuscito: ${DateTime.now().toLocal()}';
    } catch (_) {
      _failures++;
        final minutes = (1 << _failures.clamp(0, 6).toInt()).clamp(1, 60).toInt();
      _nextAttempt = DateTime.now().add(Duration(minutes: minutes));
      status = 'Invio non riuscito: verifica rete, repository e token. Nuovo tentativo tra $minutes minuti.';
    } finally {
      client.close();
      busy = false;
      notifyListeners();
    }
  }
}
