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
      runInShell: false,
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

// Resolve the actual VM executable (never a shell script, shebang wrapper or
// symlink left pointing to one). The test intentionally fails closed when no
// real VM is available; it must not claim crash safety after killing a shim.
String _dartCommand() {
  final binary = Platform.isWindows ? 'dart.exe' : 'dart';
  final candidates = <String>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    candidates.add(p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      binary,
    ));
  }
  final path = Platform.environment['PATH'] ??
      Platform.environment['Path'] ??
      '';
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.trim().isEmpty) continue;
    candidates.add(p.join(dir, 'cache', 'dart-sdk', 'bin', binary));
    candidates.add(p.join(dir, binary));
  }
  candidates.add(Platform.resolvedExecutable);
  for (final candidate in candidates) {
    try {
      final actual = File(candidate).resolveSymbolicLinksSync();
      // A wrapper in PATH might use the same filename and start a child.
      // A native executable's binary signature is required after resolving
      // symlinks; the actual process PID can then be killed reliably.
      if (p.basename(actual).toLowerCase() != binary) continue;
      final handle = File(actual).openSync();
      late final List<int> signature;
      try {
        signature = handle.readSync(4);
      } finally {
        handle.closeSync();
      }
      if (_isNativeExecutable(signature)) return actual;
    } on FileSystemException {
      // Inaccessible, missing or invalid candidate. Try the next one.
    }
  }
  throw StateError(
    'A direct native Dart VM executable is required for OS-process kill tests.',
  );
}

bool _isNativeExecutable(List<int> bytes) {
  if (bytes.length < 4) return false;
  // Linux ELF, Windows PE/MZ and macOS Mach-O / universal (fat) binaries.
  if (bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46) return true;
  if (bytes[0] == 0x4d && bytes[1] == 0x5a) return true;
  final magic = (bytes[0] << 24) |
      (bytes[1] << 16) |
      (bytes[2] << 8) |
      bytes[3];
  return const <int>{
    0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe,
    0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca,
  }.contains(magic);
}

Future<ProcessResult> _probe(String privateRoot, String scope) async {
  final child = await Process.start(
    _dartCommand(),
    <String>[_probeScript(), 'probe', privateRoot, scope],
    workingDirectory: Directory.current.path,
    runInShell: false,
  );
  final output = child.stdout.transform(utf8.decoder).join();
  final errors = child.stderr.transform(utf8.decoder).join();
  try {
    final code = await child.exitCode.timeout(const Duration(seconds: 45));
    return ProcessResult(child.pid, code, await output, await errors);
  } finally {
    // Process.run(...).timeout would leave a hung child alive after timeout.
    child.kill();
  }
}
