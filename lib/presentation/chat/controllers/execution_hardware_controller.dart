import 'dart:async' show StreamSubscription;

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
  static const String _fallbackBackendLabel = 'fallback-llama';
  static const int _kLogScanWindowSize = 32;
  static final RegExp _backendRegExp = RegExp(r'\bbackend=([a-z0-9._-]+)', caseSensitive: false);
  static final RegExp _fallbackBackendRegExp =
      RegExp(r'\bfallback=([a-z0-9._-]+)', caseSensitive: false);
  static final RegExp _vulkanRegExp = RegExp(r'\bvulkan=(enabled|disabled)\b', caseSensitive: false);

  StreamSubscription<RuntimeEventEntry>? _runtimeEventSubscription;
  StreamSubscription<void>? _runtimeLogClearSubscription;
  String? _cachedBackendFromLogs;
  int _cachedLogCount = 0;

  ExecutionHardwareController() : super(const HardwareSnapshot()) {
    _runtimeEventSubscription = RuntimeEventLog.instance.stream.listen((entry) {
      if (_entryContainsBackendInfo(entry.message)) {
        refreshHardwareStatus();
      }
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('[RuntimeHardware] log stream error: $error\n$stackTrace');
    });
    _runtimeLogClearSubscription = RuntimeEventLog.instance.onClear.listen((_) {
      _cachedBackendFromLogs = null;
      _cachedLogCount = 0;
      refreshHardwareStatus();
    });
  }

  /// Interroga l'infrastruttura nativa e i log runtime per verificare il backend effettivo di llama.cpp.
  void refreshHardwareStatus() {
    var gpuBackend = _resolveBackendFromRuntimeLogs() ?? 'unknown';
    final gpuActive = _isAcceleratedBackend(gpuBackend);

    value = HardwareSnapshot(
      gpuAccelerationActive: gpuActive,
      gpuBackend: gpuBackend,
    );
  }

  @Deprecated('Use refreshHardwareStatus instead.')
  Future<void> updateHardwareStatus() async {
    refreshHardwareStatus();
  }

  @override
  void dispose() {
    final subscription = _runtimeEventSubscription;
    final clearSubscription = _runtimeLogClearSubscription;
    _runtimeEventSubscription = null;
    _runtimeLogClearSubscription = null;
    subscription?.cancel();
    clearSubscription?.cancel();
    super.dispose();
  }

  String? _resolveBackendFromRuntimeLogs() {
    final entries = RuntimeEventLog.instance.entries;
    if (_cachedBackendFromLogs != null && entries.length == _cachedLogCount) {
      return _cachedBackendFromLogs;
    }

    final startIndex = entries.length > _kLogScanWindowSize
        ? entries.length - _kLogScanWindowSize
        : 0;
    for (var index = entries.length - 1; index >= startIndex; index--) {
      final entry = entries[index];
      final backend = backendFromRuntimeLog(entry.message);
      if (backend != null) {
        _cachedBackendFromLogs = backend;
        _cachedLogCount = entries.length;
        return backend;
      }
    }

    if (_cachedBackendFromLogs != null) {
      _cachedLogCount = entries.length;
      return _cachedBackendFromLogs;
    }

    _cachedLogCount = entries.length;
    return null;
  }

  static bool _entryContainsBackendInfo(String message) {
    return backendFromRuntimeLog(message) != null ||
        _vulkanRegExp.hasMatch(message);
  }

  static String? backendFromRuntimeLog(String message) {
    final backendMatch = _backendRegExp.firstMatch(message);
    if (backendMatch != null) {
      return normalizeBackendName(backendMatch.group(1));
    }

    final fallbackMatch = _fallbackBackendRegExp.firstMatch(message);
    if (fallbackMatch != null) {
      return normalizeBackendName(fallbackMatch.group(1));
    }

    final vulkanMatch = _vulkanRegExp.firstMatch(message);
    if (vulkanMatch != null) {
      return vulkanMatch.group(1)?.toLowerCase() == 'enabled' ? 'vulkan' : 'cpu';
    }

    return null;
  }

  static String normalizeBackendName(String? backend) {
    final normalized = (backend ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'unknown';
    }
    if (normalized == _fallbackBackendLabel) {
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
