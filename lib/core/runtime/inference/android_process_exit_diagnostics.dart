import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Android retains process exits that cannot reach a Dart exception handler.
/// Historical records are timestamped; they are not evidence of a new crash.
Future<void> recordAndroidProcessExitHistory() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  const channel = MethodChannel('com.aiorchestrator/process_exit');
  try {
    // Keep the logging continuation on the original platform future. A timeout
    // limits startup waiting, but must not discard a late tombstone response.
    final recording = channel.invokeListMethod<dynamic>('readHistory').then<void>(
      (records) {
        for (final record in records ?? const <dynamic>[]) {
          RuntimeEventLog.instance.emit(
            '[ANDROID_PROCESS_EXIT_HISTORY] ${jsonEncode(record)}',
          );
        }
      },
    );
    await recording.timeout(const Duration(seconds: 2));
  } on Object catch (error) {
    // Diagnostics must never delay or prevent startup.
    RuntimeEventLog.instance.emit('[ANDROID_PROCESS_EXIT_UNAVAILABLE] $error');
  }
}
