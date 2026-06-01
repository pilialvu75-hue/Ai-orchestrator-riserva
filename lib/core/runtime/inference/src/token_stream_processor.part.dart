part of '../android_ffi_runtime_provider.dart';

class _AndroidFfiTokenStreamProcessor {
  _AndroidFfiTokenStreamProcessor(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  String sanitizeStructuralTemplateOutput(String input) {
    if (input.isEmpty) {
      return input;
    }
    final normalizedLines = <String>[];
    for (final rawLine in input.split('\n')) {
      normalizedLines.add(rawLine.replaceAll('\r', ''));
    }
    final sanitizedLines = <String>[];
    final pendingRoleLabelIndices = <int>[];
    final skippedRoleLabelIndices = <int>{};
    var hasSeenStructuralMarker = false;
    for (final line in normalizedLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        sanitizedLines.add(line);
        continue;
      }
      if (AndroidFfiRuntimeProvider._structuralMarkerLines.contains(trimmed)) {
        hasSeenStructuralMarker = true;
        if (pendingRoleLabelIndices.isNotEmpty) {
          for (final index in pendingRoleLabelIndices) {
            skippedRoleLabelIndices.add(index);
          }
          pendingRoleLabelIndices.clear();
        }
        continue;
      }
      if (AndroidFfiRuntimeProvider._structuralRoleLabelLines.contains(trimmed)) {
        if (hasSeenStructuralMarker) {
          continue;
        }
        final roleLabelIndex = sanitizedLines.length;
        pendingRoleLabelIndices.add(roleLabelIndex);
        sanitizedLines.add(line);
        continue;
      }
      sanitizedLines.add(line);
    }
    final outputLines = <String>[];
    for (var i = 0; i < sanitizedLines.length; i++) {
      if (!skippedRoleLabelIndices.contains(i)) {
        outputLines.add(sanitizedLines[i]);
      }
    }
    return outputLines.join('\n');
  }

  bool isNoiseToken(String piece) {
    return piece.isEmpty || AndroidFfiRuntimeProvider._systemSanityTags.contains(piece);
  }

  DateTime? handleFirstTokenIfNeeded(String piece) {
    if (!_owner._preFirstTokenActive) {
      return null;
    }
    _owner._preFirstTokenActive = false;
    _owner._setPhase(RuntimePhase.streaming);
    final now = DateTime.now();
    _log(
      '[FIRST_TOKEN_PHASE] phase=${_owner._runtimePhase.name} chars=${piece.length} ts=${now.microsecondsSinceEpoch}',
    );
    return now;
  }

  void throttledLoopLog(String message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _owner._lastLoopLogAtMs >= AndroidFfiRuntimeProvider._loopLogThrottleMs) {
      _owner._lastLoopLogAtMs = now;
      _log(message);
    }
  }

  void increaseIdleBackoff() {
    _owner._idleBackoffMs = (_owner._idleBackoffMs * 2).clamp(24, 200);
  }

  void resetIdleBackoff() {
    _owner._idleBackoffMs = 24;
  }

  void _log(String message) {
    AndroidFfiRuntimeProvider._log(message);
  }
}
