import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Executable negative fixtures derived from the +3184 emitted black-star app.
/// They are deliberately invalid: the real SDK tools must reject them.
/// Never use an LLM verdict or prompt wording as proof of compilation.
void main() {
  test('Dart analyzer rejects unresolved star widget, Random and int Color',
      () async {
    final scratch = await Directory('test/app_factory/workshop')
        .createTemp('cantiere_star_bad_dart_');
    try {
      final source = File('${scratch.path}/broken_star.dart');
      await source.writeAsString(r'''
import 'package:flutter/material.dart';

void main() {
  runApp(MaterialApp(
    home: Container(color: 0xFF000000, child: StarWidget()),
  ));
}

final randomColor = Random().nextInt(16777216);
''');
      // Uses the installed SDK analyzer, the same static checker invoked by
      // the generated application's local toolchain / Build Lab.
      final result = await Process.run(
        'dart',
        <String>['analyze', source.path],
        workingDirectory: Directory.current.path,
        runInShell: false,
      );
      final output = '${result.stdout}\n${result.stderr}';
      expect(result.exitCode, isNot(0), reason: output);
      expect(output, contains('broken_star.dart'));
      expect(output, contains('StarWidget'));
      expect(output, contains('Random'));
      expect(output, contains('color'));
    } finally {
      await scratch.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Android AAPT2 rejects malformed generated drawable XML', () async {
    // The Android workflow provides the same AAPT2 resource compiler that
    // Gradle uses. Desktop CI without an Android SDK cannot run this gate.
    final sdk = Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];
    if (sdk == null || sdk.trim().isEmpty) return;
    final buildTools = Directory('$sdk/build-tools');
    expect(await buildTools.exists(), isTrue);
    final binaries = await buildTools.list().where((item) =>
        item is Directory).cast<Directory>().toList();
    binaries.sort((a, b) => b.path.compareTo(a.path));
    final executable = Platform.isWindows ? 'aapt2.exe' : 'aapt2';
    final tools = binaries
        .map((dir) => File('${dir.path}/$executable'))
        .where((f) => f.existsSync())
        .toList();
    expect(tools, isNotEmpty, reason: 'Installed Android SDK lacks AAPT2.');
    final scratch = await Directory('test/app_factory/workshop')
        .createTemp('cantiere_star_bad_xml_');
    try {
      final drawable = await Directory('${scratch.path}/res/drawable')
          .create(recursive: true);
      final xml = File('${drawable.path}/star.xml');
      // Exact malformed prefix of the +3184 generated star.xml source.
      await xml.writeAsString('color="0xFF000000"/>\n'
          '<shape xmlns:android="http://schemas.android.com/apk/res/android" '
          'android:shape="rectangle"/>');
      final outDir = await Directory('${scratch.path}/compiled').create();
      final result = await Process.run(
        tools.first.path,
        <String>['compile', '-o', outDir.path, xml.path],
        workingDirectory: Directory.current.path,
        runInShell: false,
      );
      expect(result.exitCode, isNot(0),
          reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await scratch.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
