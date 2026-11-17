import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_file_authority_gate.dart';

/// Real OS-process tests, rather than multiple Dart isolates in one process.
/// These tests stay offline and never dispatch GitHub or run production builds.
void main() {
  late Directory root;
  const scope = 'same-durable-store';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('durable-process-authority-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  WorkshopDurableFileAuthorityGate gate() =>
      WorkshopDurableFileAuthorityGate(
        privateRoot: root,
        schedulerScope: scope,
      );

  test('separate OS process cannot enter while this process owns the gate',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final owner = gate().run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      final result = await _probe(root.path, scope);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout.toString().trim(), 'blocked');
    } finally {
      release.complete();
      await owner;
    }
    final afterRelease = await _probe(root.path, scope);
    expect(afterRelease.exitCode, 0, reason: afterRelease.stderr.toString());
    expect(afterRelease.stdout.toString().trim(), 'acquired');
  });

  test('killed OS owner leaves an orphan; the next process fails closed',
      () async {
    final child = await Process.start(
      _dartCommand(),
      <String>[_probeScript(), 'hold', root.path, scope],
      workingDirectory: Directory.current.path,
      runInShell: Platform.isWindows,
    );
    // Drain stderr as soon as process starts to avoid a blocked pipe.
    final childStderr = child.stderr.transform(utf8.decoder).join();
    try {
      final marker = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 45));
      expect(marker, 'held', reason: 'OS owner did not acquire its gate');
      final concurrent = await _probe(root.path, scope);
      expect(concurrent.exitCode, 0, reason: concurrent.stderr.toString());
      expect(concurrent.stdout.toString().trim(), 'blocked');

      expect(child.kill(), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 20));
      expect(await File(gate().lockPath).exists(), isTrue);
      final afterCrash = await _probe(root.path, scope);
      expect(afterCrash.exitCode, 0, reason: afterCrash.stderr.toString());
      expect(afterCrash.stdout.toString().trim(), 'blocked');
    } finally {
      child.kill();
      await child.exitCode.timeout(const Duration(seconds: 20));
      await childStderr;
    }
  });
}

String _probeScript() => p.join(
      Directory.current.path,
      'test',
      'app_factory',
      'workshop',
      'durable',
      'support',
      'durable_authority_process_probe.dart',
    );

String _dartCommand() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    final installed = File(p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    ));
    if (installed.existsSync()) return installed.path;
  }
  // Flutter's ordinary development setup puts the Dart wrapper in PATH.
  return 'dart';
}

Future<ProcessResult> _probe(String privateRoot, String scope) =>
    Process.run(
      _dartCommand(),
      <String>[_probeScript(), 'probe', privateRoot, scope],
      workingDirectory: Directory.current.path,
      runInShell: Platform.isWindows,
    ).timeout(const Duration(seconds: 45));
