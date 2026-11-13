import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// Android read-only desktop observation based on the existing ScreenVision
/// MediaProjection bridge. Consent must be requested from a trusted UI gesture
/// through the established ScreenVision flow, not from a model/tool call.
///
/// This adapter intentionally CANNOT click, type or enable an interactive
/// ComputerUseSession; AccessibilityService is a separate permission and
/// distribution-policy design decision.
final class AndroidComputerUseAdapter
    implements ComputerUseAdapter, ComputerUseInteractionCapability {
  AndroidComputerUseAdapter({
    MethodChannel? channel,
    bool? supportedForTest,
  })  : _channel = channel ??
            const MethodChannel('com.aiorchestrator/screen_vision'),
        _supportedForTest = supportedForTest;

  final MethodChannel _channel;

  /// Test hook only: production always uses the actual Android platform.
  final bool? _supportedForTest;
  int _generation = 0;

  @override
  bool get isSupported => _supportedForTest ?? Platform.isAndroid;

  @override
  bool get supportsInteraction => false;

  @override
  void cancel() {
    _generation++;
    // Deliberately do not stop ScreenVision: another feature may own it.
    // A late capture is rejected by the generation check.
  }

  @override
  Future<Uint8List> capturePng() async {
    if (!isSupported) throw _unsupported();
    final generation = _generation;
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getStatus',
      );
      if (status?['active'] != true) {
        throw const ComputerUseException(
          'SCREEN_CONSENT_REQUIRED',
          'Enable Android screen sharing through the existing owner UI first.',
        );
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
        'captureScreenshot',
      );
      if (generation != _generation) {
        throw const ComputerUseException(
          'SESSION_REVOKED',
          'A screen capture finished after STOP.',
        );
      }
      if (bytes == null || bytes.isEmpty) {
        throw const ComputerUseException(
          'INVALID_FRAME',
          'Android returned no screen frame.',
        );
      }
      return bytes;
    } on PlatformException {
      throw const ComputerUseException(
        'SCREEN_CAPTURE_FAILED',
        'The Android screen capture service is unavailable.',
      );
    } on MissingPluginException {
      throw const ComputerUseException(
        'SCREEN_VISION_UNAVAILABLE',
        'The native ScreenVision bridge is not registered.',
      );
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
        'Android Computer Use currently supports observation only.',
      );

  static ComputerUseException _unsupported() =>
      const ComputerUseException(
        'UNSUPPORTED_HOST',
        'This adapter only runs on Android.',
      );
}
