import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/core/voice/voice_archive_worker.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _uiDownloadCompletion(
  String archive, String destination, void Function() onComplete,
) async {
  await extractVoiceArchiveInBackground(archive, destination);
  onComplete();
}

void main() {
  test('archive extraction does not capture the caller timer callback', () async {
    final directory = await Directory.systemTemp.createTemp('voice-extraction');
    final timer = Timer.periodic(const Duration(hours: 1), (_) {});
    try {
      final archive = File('${directory.path}/fixture.zip');
      await archive.writeAsBytes(base64Decode(
        'UEsDBBQAAAAAAG4sK11itqMnCwAAAAsAAAAKAAAAdG9rZW5zLnR4dHRlc3QgdG9rZW5zUEsBAhQDFAAAAAAAbiwrXWK2oycLAAAACwAAAAoAAAAAAAAAAAAAAIABAAAAAHRva2Vucy50eHRQSwUGAAAAAAEAAQA4AAAAMwAAAAAA',
      ));
      var completed = false;
      await _uiDownloadCompletion(archive.path, '${directory.path}/output', () {
        timer.cancel();
        completed = true;
      });
      expect(completed, isTrue);
      expect(await File('${directory.path}/output/tokens.txt').readAsString(),
          'test tokens');
    } finally {
      timer.cancel();
      await directory.delete(recursive: true);
    }
  });
}
