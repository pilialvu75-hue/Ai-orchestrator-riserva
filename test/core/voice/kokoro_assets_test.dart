import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/kokoro_assets.dart';

void main() {
  test('package verification rejects missing, altered and truncated assets', () async {
    final dir = await Directory.systemTemp.createTemp('kokoro-test-');
    try {
      expect(await KokoroAssets.verifyDirectory(dir.path), isNull);
      final hashes = <String, String>{};
      for (final name in ['model.onnx', 'voices.bin', 'tokens.txt',
        'data/phontab', 'data/phondata', 'data/phonindex', 'data/intonations']) {
        final file = File('${dir.path}/$name');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        hashes[name] = sha256.convert([1, 2, 3]).toString();
      }
      final manifest = {
        'archiveSha256': KokoroAssets.archiveSha256,
        'files': hashes,
        'paths': {'model': 'model.onnx', 'voices': 'voices.bin',
          'tokens': 'tokens.txt', 'data': 'data'},
      };
      await File('${dir.path}/verified.json').writeAsString(jsonEncode(manifest));
      expect(await KokoroAssets.verifyDirectory(dir.path), isNotNull);
      await File('${dir.path}/model.onnx').writeAsBytes([1, 2, 4]);
      expect(await KokoroAssets.verifyDirectory(dir.path), isNull);
      await File('${dir.path}/model.onnx').writeAsBytes([1, 2]);
      expect(await KokoroAssets.verifyDirectory(dir.path), isNull);
      await File('${dir.path}/model.onnx').writeAsBytes([1, 2, 3]);
      await File('${dir.path}/data/phontab').delete();
      expect(await KokoroAssets.verifyDirectory(dir.path), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
