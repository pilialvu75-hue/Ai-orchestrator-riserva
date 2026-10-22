import 'dart:io';
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
      await KokoroAssets.extractVerifiedArchive(archive!, payload.path);
      print('KOKORO_STAGE_COMPLETE elapsed_ms=${watch.elapsedMilliseconds}');
      final verified = await KokoroAssets.verifyDirectory(payload.path);
      expect(verified, isNotNull, reason: 'Extracted official payload must remain trusted after verification.');
      expect(verified!.keys, containsAll(['model', 'voices', 'tokens', 'data']));
      expect(await File(verified['model']!).length(), 325560556);
      print('KOKORO_VERIFY_COMPLETE elapsed_ms=${watch.elapsedMilliseconds}');
    } finally {
      await temporary.delete(recursive: true);
    }
  }, skip: archive == null, timeout: const Timeout(Duration(minutes: 15)));
}
