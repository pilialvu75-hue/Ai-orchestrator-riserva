import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

@immutable
class HardwareSnapshot {
  final bool gpuAccelerationActive;
  final String gpuBackend;

  const HardwareSnapshot({
    this.gpuAccelerationActive = false,
    this.gpuBackend = 'unknown',
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HardwareSnapshot &&
          runtimeType == other.runtimeType &&
          gpuAccelerationActive == other.gpuAccelerationActive &&
          gpuBackend == other.gpuBackend;

  @override
  int get hashCode => Object.hash(gpuAccelerationActive, gpuBackend);
}

class ExecutionHardwareController extends ValueNotifier<HardwareSnapshot> {
  static final RegExp _backendRegExp = RegExp(r'\bbackend=([a-z0-9._-]+)', caseSensitive: false);
  static final RegExp _fallbackBackendRegExp =
      RegExp(r'\bfallback=([a-z0-9._-]+)', caseSensitive: false);
  static final RegExp _vulkanRegExp = RegExp(r'\bvulkan=(enabled|disabled)\b', caseSensitive: false);

  StreamSubscription<RuntimeEventEntry>? _runtimeEventSubscription;

  ExecutionHardwareController() : super(const HardwareSnapshot()) {
    _runtimeEventSubscription = RuntimeEventLog.instance.stream.listen((entry) {
      if (_entryContainsBackendInfo(entry.message)) {
        unawaited(refreshHardwareStatus());
      }
    });
  }

  /// Interroga l'infrastruttura nativa e i log runtime per verificare il backend effettivo di llama.cpp.
  Future<void> refreshHardwareStatus() {
    var gpuActive = false;
    var gpuBackend = _resolveBackendFromRuntimeLogs() ?? 'unknown';
    gpuActive = _isAcceleratedBackend(gpuBackend);

    value = HardwareSnapshot(
      gpuAccelerationActive: gpuActive,
      gpuBackend: gpuBackend,
    );
    return Future<void>.value();
  }

  @Deprecated('Use refreshHardwareStatus instead.')
  Future<void> updateHardwareStatus() => refreshHardwareStatus();

  @override
  void dispose() {
    final subscription = _runtimeEventSubscription;
    _runtimeEventSubscription = null;
    unawaited(subscription?.cancel());
    super.dispose();
  }

  static String? _resolveBackendFromRuntimeLogs() {
    final entries = RuntimeEventLog.instance.entries;
    for (var index = entries.length - 1; index >= 0; index--) {
      final entry = entries[index];
      final backend = backendFromRuntimeLog(entry.message);
      if (backend != null) {
        return backend;
      }
    }
    return null;
  }

  static bool _entryContainsBackendInfo(String message) {
    return backendFromRuntimeLog(message) != null ||
        _vulkanRegExp.hasMatch(message);
  }

  static String? backendFromRuntimeLog(String message) {
    final backendMatch = _backendRegExp.firstMatch(message);
    if (backendMatch != null) {
      return _normalizeBackendName(backendMatch.group(1));
    }

    final fallbackMatch = _fallbackBackendRegExp.firstMatch(message);
    if (fallbackMatch != null) {
      return _normalizeBackendName(fallbackMatch.group(1));
    }

    final vulkanMatch = _vulkanRegExp.firstMatch(message);
    if (vulkanMatch != null) {
      return vulkanMatch.group(1)?.toLowerCase() == 'enabled' ? 'vulkan' : 'cpu';
    }

    return null;
  }

  static String _normalizeBackendName(String? backend) {
    final normalized = (backend ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'unknown';
    }
    if (normalized == 'fallback-llama') {
      return 'cpu';
    }
    return normalized;
  }

  static bool _isAcceleratedBackend(String backend) {
    final normalized = backend.toLowerCase();
    return normalized.isNotEmpty &&
        normalized != 'cpu' &&
        normalized != 'unknown' &&
        normalized != 'unavailable';
  }
}
