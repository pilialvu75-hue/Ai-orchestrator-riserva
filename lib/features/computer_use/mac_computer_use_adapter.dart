import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// macOS read-only capture via the app's native CoreGraphics bridge.
/// No shell process is launched and the LLM cannot request TCC permission.
/// That request is reserved for an explicit user gesture in the lab UI.
///
/// ScreenCaptureKit remains the future backend for long-lived vision streams.
final class MacComputerUseAdapter
    implements ComputerUseAdapter, ComputerUseInteractionCapability {
  MacComputerUseAdapter({
    MethodChannel? channel,
    bool? supportedForTest,
  })  : _channel = channel ??
            const MethodChannel('com.aiorchestrator/computer_use_mac'),
        _supportedForTest = supportedForTest;

  final MethodChannel _channel;
  final bool? _supportedForTest;
  int _generation = 0;

  @override
  bool get isSupported => _supportedForTest ?? Platform.isMacOS;

  @override
  bool get supportsInteraction => false;

  @override
  void cancel() {
    _generation++;
  }

  @override
  Future<Uint8List> capturePng() async {
    if (!isSupported) throw _unsupported();
    final generation = _generation;
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getStatus',
      );
      if (status?['authorized'] != true) {
        throw const ComputerUseException(
          'SCREEN_CONSENT_REQUIRED',
          'Allow Screen Recording in macOS System Settings.',
        );
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
        'captureScreenshot',
      );
      if (generation != _generation) {
        throw const ComputerUseException(
          'SESSION_REVOKED',
          'The authorized screen capture was cancelled.',
        );
      }
      if (bytes == null || bytes.isEmpty) {
        throw const ComputerUseException(
          'INVALID_FRAME',
          'macOS returned no screen frame.',
        );
      }
      return bytes;
    } on PlatformException catch (error) {
      if (error.code == 'SCREEN_CONSENT_REQUIRED') {
        throw const ComputerUseException(
          'SCREEN_CONSENT_REQUIRED',
          'Allow Screen Recording in macOS System Settings.',
        );
      }
      throw const ComputerUseException(
        'SCREEN_CAPTURE_FAILED',
        'The native macOS capture failed.',
      );
    } on MissingPluginException {
      throw const ComputerUseException(
        'MAC_CAPTURE_UNAVAILABLE',
        'The macOS Screen Recording bridge is not registered.',
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
        'macOS input is disabled pending Accessibility-permission QA.',
      );

  static ComputerUseException _unsupported() =>
      const ComputerUseException(
        'UNSUPPORTED_HOST',
        'This adapter only runs on macOS.',
      );
}
