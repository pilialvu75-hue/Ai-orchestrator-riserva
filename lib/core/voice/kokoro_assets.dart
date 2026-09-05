import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:ai_orchestrator/core/storage/runtime_model_path_resolver.dart';

/// Official Sherpa Kokoro v1.0 INT8 bundle. Paola files are never reused.
class KokoroAssets {
  static const archiveName = 'kokoro-int8-multi-lang-v1_0.tar.bz2';
  static const archiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
      'kokoro-int8-multi-lang-v1_0.tar.bz2';
  static const archiveBytes = 131839838;
  static const archiveSha256 =
      '75654a84864be26f345f020f4070c2c019e96dd1b7f9bf6e2ffd59efac6aa5a3';
  static const directoryName = 'kokoro-v1_0-int8';
  static Future<void>? _installing;

  static Future<Directory> directory() async {
    final root = await const RuntimeModelPathResolver().privateModelsDirectory();
    return Directory(p.join(root.path, directoryName));
  }

  static Future<Map<String, String>?> verifiedPaths() async {
    final dir = await directory();
    return Isolate.run(() => verifyDirectory(dir.path));
  }

  static Future<void> install(void Function(double) onProgress) async {
    final pending = _installing;
    if (pending != null) {
      await pending;
      onProgress(1);
      return;
    }
    final operation = _install(onProgress);
    _installing = operation;
    try {
      await operation;
    } finally {
      if (identical(_installing, operation)) _installing = null;
    }
  }

  static Future<void> _install(void Function(double) onProgress) async {
    final destination = await directory();
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.kokoro-install-');
    final archive = File(p.join(staging.path, archiveName));
    final dio = Dio();
    try {
      await dio.download(archiveUrl, archive.path,
          options: Options(receiveTimeout: const Duration(minutes: 15)),
          onReceiveProgress: (received, total) {
        onProgress((received / archiveBytes * 0.8).clamp(0.0, 0.8).toDouble());
      });
      final payload = p.join(staging.path, 'payload');
      await Isolate.run(() async {
        if (await archive.length() != archiveBytes ||
            (await sha256.bind(archive.openRead()).first).toString() != archiveSha256) {
          throw const FormatException('Archivio Kokoro incompleto o corrotto. Riprovare il download.');
        }
        await extractFileToDisk(archive.path, payload);
        final files = Directory(payload).listSync(recursive: true, followLinks: false)
            .whereType<File>().toList();
        File unique(String name) {
          final matches = files.where((f) => p.basename(f.path) == name).toList();
          if (matches.length != 1) throw FormatException('Risorsa Kokoro mancante o ambigua: $name');
          return matches.single;
        }
        final models = files.where((f) => f.path.endsWith('.onnx')).toList();
        if (models.length != 1) throw const FormatException('Modello Kokoro mancante o ambiguo.');
        final model = models.single;
        final voices = unique('voices.bin');
        final tokens = unique('tokens.txt');
        final phontab = unique('phontab');
        final data = phontab.parent;
        for (final name in ['phondata', 'phonindex', 'intonations']) {
          if (!File(p.join(data.path, name)).existsSync()) {
            throw FormatException('Dati pronuncia Kokoro incompleti: $name');
          }
        }
        final hashes = <String, String>{};
        for (final file in files) {
          hashes[p.relative(file.path, from: payload)] =
              (await sha256.bind(file.openRead()).first).toString();
        }
        await File(p.join(payload, 'verified.json')).writeAsString(jsonEncode({
          'archiveSha256': archiveSha256,
          'files': hashes,
          'paths': {
            'model': p.relative(model.path, from: payload),
            'voices': p.relative(voices.path, from: payload),
            'tokens': p.relative(tokens.path, from: payload),
            'data': p.relative(data.path, from: payload),
          },
        }), flush: true);
      });
      onProgress(0.95);
      // Preserve the previous package until a complete replacement is ready.
      final backup = Directory(p.join(staging.path, 'previous'));
      if (await destination.exists()) await destination.rename(backup.path);
      try {
        await Directory(payload).rename(destination.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(destination.path);
        rethrow;
      }
      onProgress(1);
    } finally {
      dio.close();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static Future<Map<String, String>?> verifyDirectory(String root) async {
    try {
      final manifest = jsonDecode(await File(p.join(root, 'verified.json')).readAsString())
          as Map<String, dynamic>;
      if (manifest['archiveSha256'] != archiveSha256) return null;
      String inside(String relative) {
        final full = p.normalize(p.join(root, relative));
        if (!p.isWithin(root, full)) throw const FormatException('Invalid asset path');
        return full;
      }
      final files = Map<String, dynamic>.from(manifest['files'] as Map);
      if (files.isEmpty) return null;
      for (final entry in files.entries) {
        final file = File(inside(entry.key));
        if ((await sha256.bind(file.openRead()).first).toString() != entry.value) return null;
      }
      final paths = Map<String, dynamic>.from(manifest['paths'] as Map);
      for (final key in ['model', 'voices', 'tokens']) {
        if (!files.containsKey(paths[key])) return null;
      }
      final data = paths['data'] as String;
      for (final name in ['phontab', 'phondata', 'phonindex', 'intonations']) {
        if (!files.containsKey(p.join(data, name))) return null;
      }
      return paths.map((key, value) => MapEntry(key, inside(value as String)));
    } on Object {
      return null;
    }
  }
}
