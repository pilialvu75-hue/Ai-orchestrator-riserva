import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/kokoro_assets.dart';

void main() {
  final archive = Platform.environment['AI_ORCHESTRATOR_KOKORO_ARCHIVE'];
  test('official Kokoro archive stages and verifies on this platform', () async {
    final temporary = await Directory.systemTemp.createTemp('kokoro-live-');
    final watch = Stopwatch()..start();
    try {
      final payload = Directory('${temporary.path}/payload');
      print('KOKORO_STAGE_BEGIN platform=${Platform.operatingSystem}');
      final archivePath = archive!;
      final payloadPath = payload.path;
      await Isolate.run(() => KokoroAssets.extractVerifiedArchive(archivePath, payloadPath));
      print('KOKORO_STAGE_COMPLETE elapsed_ms=${watch.elapsedMilliseconds}');
      // Exercise the same-directory activation rename without touching app data.
      final destination = Directory('${temporary.path}/installed');
      await destination.create();
      final sentinel = File('${destination.path}/previous.txt');
      await sentinel.writeAsString('previous installation');
      final backup = Directory('${temporary.path}/previous');
      await destination.rename(backup.path);
      try {
        await payload.rename(destination.path);
      } catch (_) {
        await backup.rename(destination.path);
        rethrow;
      }
      expect(await File('${backup.path}/previous.txt').readAsString(), 'previous installation');
      final destinationPath = destination.path;
      final verified = await Isolate.run(() => KokoroAssets.verifyDirectory(destinationPath));
      expect(verified, isNotNull, reason: 'Extracted official payload must remain trusted after verification.');
      expect(verified!.keys, containsAll(['model', 'voices', 'tokens', 'data']));
      expect(await File(verified['model']!).length(), 325560556);
      // A pre-repack installation must remain usable after upgrading the app.
      final manifestFile = File('${destination.path}/verified.json');
      final manifest = jsonDecode(await manifestFile.readAsString())
          as Map<String, dynamic>;
      manifest['archiveSha256'] =
          'c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298';
      await manifestFile.writeAsString(jsonEncode(manifest));
      expect(await KokoroAssets.verifyDirectory(destinationPath), isNotNull);
      // Backward compatibility must not bypass the per-file integrity check.
      await File(verified['tokens']!).writeAsString('corrupt test payload');
      expect(await KokoroAssets.verifyDirectory(destinationPath), isNull);
      print('KOKORO_VERIFY_COMPLETE elapsed_ms=${watch.elapsedMilliseconds}');
    } finally {
      await temporary.delete(recursive: true);
    }
  }, skip: archive == null, timeout: const Timeout(Duration(minutes: 15)));
}
