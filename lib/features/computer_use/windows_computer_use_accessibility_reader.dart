import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_orchestrator/features/computer_use/computer_use_local_json_planner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';

/// A LOCAL-only, accessibility-based summary for a selected Windows window.
/// No network calls and no document or text field values. The separate host
/// adapter obtains the bounded UI Automation tree without input or focus.
final class WindowsComputerUseAccessibilityReader
    implements ComputerUseLocalScreenReader {
  WindowsComputerUseAccessibilityReader({
    required ComputerUseSession session,
    required Future<String> Function() captureAccessibilityJson,
  })  : _session = session,
        _captureAccessibilityJson = captureAccessibilityJson;

  final ComputerUseSession _session;
  final Future<String> Function() _captureAccessibilityJson;

  @override
  Future<ComputerUseScreenSummary> describe(Uint8List framePng) async {
    if (!_session.isActive) {
      throw const ComputerUseException(
        'SESSION_INACTIVE', 'Accessibility needs an authorized session.',
      );
    }
    final revision = _session.sessionRevision;
    final raw = await _captureAccessibilityJson();
    // A STOP + new grant must never reuse controls from the old task.
    if (!_session.isActive || _session.sessionRevision != revision) {
      throw const ComputerUseException(
        'SESSION_REVOKED', 'Accessibility session was revoked.',
      );
    }
    if (raw.length > 12000) {
      return const ComputerUseScreenSummary(
        description: '', sensitive: true,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const ComputerUseScreenSummary(
        description: '', sensitive: true,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['sensitive'] is! bool ||
        decoded['description'] is! String) {
      return const ComputerUseScreenSummary(
        description: '', sensitive: true,
      );
    }
    final sensitive = decoded['sensitive'] as bool;
    final description = decoded['description'] as String;
    // A malformed host result or sensitive screen is never sent to the LLM.
    if (sensitive ||
        description.trim().isEmpty ||
        description.length > 6000 ||
        description.split('\n').length > 64 ||
        _sensitiveHint.hasMatch(description)) {
      return const ComputerUseScreenSummary(
        description: '', sensitive: true,
      );
    }
    return ComputerUseScreenSummary(
      description: description.trim(), sensitive: false,
    );
  }

  static final RegExp _sensitiveHint = RegExp(
    r'password|passcode|credit.card|card.number|bank.account|'
    r'security.code|two.factor|verification.code',
    caseSensitive: false,
  );
}
