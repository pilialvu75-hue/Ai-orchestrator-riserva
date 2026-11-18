import 'dart:io';

import 'package:ai_orchestrator/app_factory/workshop/durable/workshop_durable_file_authority_gate.dart';

/// Invoked by the VM test harness in a SEPARATE operating-system process.
///
/// This is never imported by the application or run by its production factory.
/// Usage: dart <script> probe|hold <privateRoot> <scope>
Future<void> main(List<String> args) async {
  if (args.length != 3 ||
      (args[0] != 'probe' && args[0] != 'hold')) {
    stderr.writeln('invalid test probe arguments');
    exitCode = 64;
    return;
  }

  final mode = args[0];
  final gate = WorkshopDurableFileAuthorityGate(
    privateRoot: Directory(args[1]),
    schedulerScope: args[2],
  );
  if (mode == 'probe') {
    try {
      await gate.run(() async {
        stdout.writeln('acquired');
        await stdout.flush();
      });
    } on StateError catch (error) {
      // Only the expected contention is a successful negative probe.
      if (!error.toString().contains('already owned or orphaned')) rethrow;
      stdout.writeln('blocked');
      await stdout.flush();
    }
    return;
  }

  // Parent test deliberately kills this process after it sees the marker.
  // Closing stdin normally would return from the action and remove the gate.
  await gate.run(() async {
    stdout.writeln('held');
    await stdout.flush();
    await stdin.drain<void>();
  });
}
