import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Observational process ownership, not a process controller.
class WindowsEngineProcessLease {
  const WindowsEngineProcessLease(this.pid, this.generation);
  final int pid;
  final int generation;
}

class WindowsEngineProcessTracker extends ChangeNotifier {
  static final instance = WindowsEngineProcessTracker();

  int _generation = 0;
  final _live = <WindowsEngineProcessLease>[];
  WindowsEngineProcessLease? get current => _live.isEmpty ? null : _live.last;

  WindowsEngineProcessLease register(int pid) {
    final lease = WindowsEngineProcessLease(pid, ++_generation);
    _live.add(lease);
    notifyListeners();
    return lease;
  }

  void unregister(WindowsEngineProcessLease lease) {
    if (_live.remove(lease)) notifyListeners();
  }

  /// Real process exits clear the exact lease, never a later reused PID.
  void track(Process process) {
    if (!Platform.isWindows) return;
    final lease = register(process.pid);
    unawaited(process.exitCode.then<void>(
      (_) => unregister(lease),
      onError: (Object error, StackTrace stack) => unregister(lease),
    ));
  }
}
