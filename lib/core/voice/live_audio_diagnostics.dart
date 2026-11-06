import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform capabilities are not evidence that acoustic echo suppression is
/// attached to the active microphone recording or actually works.
@immutable
class LiveAudioCapabilities {
  const LiveAudioCapabilities({
    required this.aecAvailable,
    required this.noiseSuppressorAvailable,
    required this.aecAttached,
    required this.echoSuppressionVerified,
    required this.automaticBargeInEnabled,
  });

  const LiveAudioCapabilities.unavailable()
      : aecAvailable = false,
        noiseSuppressorAvailable = false,
        aecAttached = false,
        echoSuppressionVerified = false,
        automaticBargeInEnabled = false;

  final bool aecAvailable;
  final bool noiseSuppressorAvailable;
  final bool aecAttached;
  final bool echoSuppressionVerified;
  final bool automaticBargeInEnabled;

  /// Fail closed even if a native response accidentally enables barge-in
  /// without a verified AEC capture path.
  bool get canInterruptFromMicrophone =>
      aecAttached && echoSuppressionVerified && automaticBargeInEnabled;

  factory LiveAudioCapabilities.fromMap(Map<Object?, Object?> data) {
    bool flag(String key) => data[key] == true;
    return LiveAudioCapabilities(
      aecAvailable: flag('aecAvailable'),
      noiseSuppressorAvailable: flag('noiseSuppressorAvailable'),
      aecAttached: flag('aecAttached'),
      echoSuppressionVerified: flag('echoSuppressionVerified'),
      automaticBargeInEnabled: flag('automaticBargeInEnabled'),
    );
  }
}

/// Diagnostics only; this does not start a second recorder or enable barge-in.
class LiveAudioDiagnostics {
  const LiveAudioDiagnostics({
    MethodChannel channel =
        const MethodChannel('com.aiorchestrator/live_audio_diagnostics'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<LiveAudioCapabilities> inspect() async {
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'getCapabilities',
      );
      if (result == null) {
        return const LiveAudioCapabilities.unavailable();
      }
      return LiveAudioCapabilities.fromMap(result);
    } on MissingPluginException {
      // Windows/macOS and older Android releases have no native bridge yet.
      return const LiveAudioCapabilities.unavailable();
    } on PlatformException {
      return const LiveAudioCapabilities.unavailable();
    }
  }
}
