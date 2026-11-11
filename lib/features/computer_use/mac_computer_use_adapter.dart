import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// macOS observation-only proof of life. Uses a fixed OS screenshot utility,
/// no shell, no model-controlled command, no arbitrary executable arguments.
///
/// Screen Recording permission must be granted explicitly in macOS System
/// Settings. Sandbox/signing support is unverified until physical Mac QA.
final class MacComputerUseAdapter
    implements ComputerUseAdapter, ComputerUseInteractionCapability {
  Process? _captureProcess;
  int _generation = 0;

  @override
  bool get isSupported => Platform.isMacOS;

  @override
  bool get supportsInteraction => false;

  @override
  void cancel() {
    _generation++;
    _captureProcess?.kill();
    _captureProcess = null;
  }

  @override
  Future<Uint8List> capturePng() async {
    if (!isSupported) throw _unsupported();
    final generation = _generation;
    final directory = await Directory.systemTemp.createTemp('aivexus_mac_cu_');
    final target = File(
      directory.path + Platform.pathSeparator + 'screen.png',
    );
    try {
      final Process process;
      try {
        process = await Process.start(
          '/usr/sbin/screencapture',
          <String>['-x', '-t', 'png', target.path],
          runInShell: false,
        );
      } on ProcessException {
        throw const ComputerUseException(
          'SCREEN_CAPTURE_UNAVAILABLE',
          'macOS screenshot utility could not start.',
        );
      }
      _captureProcess = process;
      // Consume output without logging potentially sensitive information.
      final stdoutDone = process.stdout.drain<void>();
      final stderrDone = process.stderr.drain<void>();
      final int code;
      try {
        code = await process.exitCode.timeout(
          const Duration(seconds: 15),
        );
      } on TimeoutException {
        process.kill();
        throw const ComputerUseException(
          'SCREEN_CAPTURE_TIMEOUT',
          'macOS capture exceeded its time limit.',
        );
      } finally {
        if (identical(_captureProcess, process)) _captureProcess = null;
      }
      await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
      if (generation != _generation) {
        throw const ComputerUseException(
          'SESSION_REVOKED',
          'The screen capture was cancelled.',
        );
      }
      if (code != 0 || !await target.exists()) {
        throw const ComputerUseException(
          'SCREEN_CAPTURE_FAILED',
          'macOS could not capture the screen. Check Screen Recording permission.',
        );
      }
      return await target.readAsBytes();
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Cleanup should not mask an actual capture or permission error.
      }
    }
  }

  @override
  Future<void> click(int x, int y) async => throw _readOnly();

  @override
  Future<void> typeText(String text) async => throw _readOnly();

  @override
  Future<void> pressKey(String key) async => throw _readOnly();

  @override
  Future<void> selectForegroundWindow() async => throw _readOnly();

  @override
  Future<void> openApplication(String application) async => throw _readOnly();

  @override
  Future<bool> verifyTestMarker(String marker) async => throw _readOnly();

  static ComputerUseException _readOnly() =>
      const ComputerUseException(
        'INTERACTION_UNSUPPORTED',
        'macOS input is disabled pending Accessibility-permission QA.',
      );

  static ComputerUseException _unsupported() =>
      const ComputerUseException(
        'UNSUPPORTED_HOST',
        'This adapter only runs on macOS.',
      );
}
