import 'dart:typed_data';

import 'package:ai_orchestrator/core/tools/tool.dart';

/// A host implementation never receives model-generated shell commands.
/// Operations are typed and can be independently implemented on each OS.
abstract interface class ComputerUseAdapter {
  bool get isSupported;
  Future<Uint8List> capturePng();
  Future<void> click(int x, int y);
  Future<void> typeText(String text);
  Future<void> pressKey(String key);

  /// Bind to the foreground application previously selected by the owner.
  Future<void> selectForegroundWindow();

  /// Launch a trusted application from a fixed host-maintained allowlist.
  Future<void> openApplication(String application);

  /// Aborts any ongoing host operation and releases adapter-held targeting.
  void cancel();
}

class ComputerUseException implements Exception {
  const ComputerUseException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ComputerUseException($code): $message';
}

/// A revocable, short-lived Computer Use capability.
///
/// Only trusted host UI calls [beginSession]. A model-facing [execute] call
/// cannot grant itself permissions or extend an existing session.
final class ComputerUseSession implements Tool {
  ComputerUseSession({
    required ComputerUseAdapter adapter,
    DateTime Function()? clock,
    Duration sessionLifetime = const Duration(minutes: 10),
  })  : _adapter = adapter,
        _clock = clock ?? DateTime.now,
        _sessionLifetime = sessionLifetime;

  final ComputerUseAdapter _adapter;
  final DateTime Function() _clock;
  final Duration _sessionLifetime;

  DateTime? _expiresAt;
  bool _interactive = false;
  int? _screenWidth;
  int? _screenHeight;
  bool _operationActive = false;

  @override
  String get id => 'computer_use';

  @override
  String get name => 'Computer Use';

  @override
  String get description =>
      'Observes the desktop or performs approved GUI clicks, text input, '
      'and navigation keys during an active user-authorized session. '
      'No shell commands, network access or arbitrary file operations.';

  bool get isSupported => _adapter.isSupported;

  bool get isActive =>
      isSupported && _expiresAt != null && _clock().isBefore(_expiresAt!);

  bool get canInteract => isActive && _interactive;

  DateTime? get expiresAt => isActive ? _expiresAt : null;

  /// This method must be invoked by a trusted user gesture, never a tool call.
  void beginSession({required bool allowInteraction}) {
    if (!isSupported) {
      throw const ComputerUseException(
        'UNSUPPORTED_HOST',
        'Computer Use is not supported by this host adapter.',
      );
    }
    stop();
    _expiresAt = _clock().add(_sessionLifetime);
    _interactive = allowInteraction;
  }

  void stop() {
    _adapter.cancel();
    _expiresAt = null;
    _interactive = false;
    _screenWidth = null;
    _screenHeight = null;
  }

  Future<Uint8List> captureFrame() async {
    _requireSession();
    final bytes = await _adapter.capturePng();
    // An in-flight screenshot must not revive a revoked or expired session.
    _requireSession();
    if (bytes.length < 24 ||
        bytes.length > 16 * 1024 * 1024 ||
        bytes[0] != 0x89 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x4e ||
        bytes[3] != 0x47 ||
        bytes[4] != 0x0d ||
        bytes[5] != 0x0a ||
        bytes[6] != 0x1a ||
        bytes[7] != 0x0a) {
      throw const ComputerUseException(
        'INVALID_FRAME',
        'Desktop adapter did not return a valid PNG frame (max 16 MiB).',
      );
    }
    final data = ByteData.sublistView(bytes);
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    if (width == 0 || height == 0 || width > 16384 || height > 16384) {
      throw const ComputerUseException(
        'INVALID_DIMENSIONS',
        'Desktop frame has invalid dimensions.',
      );
    }
    _screenWidth = width;
    _screenHeight = height;
    return bytes;
  }

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final action = params['action'];
    // STOP must always work, even when an operation is still in flight.
    if (action == 'stop') {
      stop();
      return _success('Computer Use session stopped.');
    }
    if (_operationActive) {
      return const ToolResult(
        toolId: 'computer_use',
        output: 'A desktop operation is already running.',
        success: false,
        error: 'OPERATION_BUSY',
      );
    }
    _operationActive = true;
    try {
      _requireSession();
      switch (action) {
        case 'open_app':
          _requireInteraction();
          final app = params['app'];
          if (app is! String || !allowedApplications.contains(app)) {
            throw const ComputerUseException(
              'APPLICATION_NOT_ALLOWED',
              'Only allowlisted non-destructive test applications are available.',
            );
          }
          await _adapter.openApplication(app);
          _requireSession();
          return _success('Test application launch requested.');
        case 'select_window':
          _requireInteraction();
          await _adapter.selectForegroundWindow();
          _requireSession();
          return _success('Foreground window selected for input.');
        case 'observe':
          await captureFrame();
          return _success(
            'Screenshot captured in memory. Not sent to a provider.',
            <String, Object?>{
              'width': _screenWidth,
              'height': _screenHeight,
              'expiresAt': _expiresAt!.toIso8601String(),
            },
          );
        case 'click':
          _requireInteraction();
          final x = params['x'];
          final y = params['y'];
          if (x is! int || y is! int || _screenWidth == null ||
              _screenHeight == null || x < 0 || y < 0 ||
              x >= _screenWidth! || y >= _screenHeight!) {
            throw const ComputerUseException(
              'INVALID_COORDINATES',
              'Observe the screen first, then click within its bounds.',
            );
          }
          await _adapter.click(x, y);
          _requireSession();
          return _success('Clicked at ($x, $y).');
        case 'type_text':
          _requireInteraction();
          final value = params['text'];
          if (value is! String || value.isEmpty || value.length > 512) {
            throw const ComputerUseException(
              'INVALID_TEXT',
              'Text must be between 1 and 512 UTF-16 code units.',
            );
          }
          await _adapter.typeText(value);
          _requireSession();
          // Deliberately never echo typed content into diagnostics.
          return _success('Text entered into the active window.');
        case 'press_key':
          _requireInteraction();
          final key = params['key'];
          if (key is! String || !allowedKeys.contains(key)) {
            throw const ComputerUseException(
              'INVALID_KEY',
              'Only allowlisted navigation keys may be pressed.',
            );
          }
          await _adapter.pressKey(key);
          _requireSession();
          return _success('Navigation key sent.');
        default:
          throw const ComputerUseException(
            'INVALID_ACTION',
            'Supported actions: observe, open_app, select_window, click, '
            'type_text, press_key, stop.',
          );
      }
    } on ComputerUseException catch (error) {
      return ToolResult(
        toolId: id,
        output: error.message,
        success: false,
        error: error.code,
      );
    } catch (_) {
      return const ToolResult(
        toolId: 'computer_use',
        output: 'The desktop operation failed.',
        success: false,
        error: 'ADAPTER_ERROR',
      );
    } finally {
      _operationActive = false;
    }
  }

  static const Set<String> allowedApplications = <String>{
    'notepad',
    'calculator',
  };

  static const Set<String> allowedKeys = <String>{
    'enter', 'tab', 'escape', 'backspace',
    'up', 'down', 'left', 'right', 'ctrl+a',
  };

  void _requireSession() {
    if (!isActive) {
      stop();
      throw const ComputerUseException(
        'SESSION_INACTIVE',
        'Start a Computer Use session from the host UI.',
      );
    }
  }

  void _requireInteraction() {
    if (!_interactive) {
      throw const ComputerUseException(
        'READ_ONLY_SESSION',
        'This session only allows screen observation.',
      );
    }
  }

  ToolResult _success(
    String message, [
    Map<String, Object?> metadata = const <String, Object?>{},
  ]) =>
      ToolResult(toolId: id, output: message, metadata: metadata);
}
