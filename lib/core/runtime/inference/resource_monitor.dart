import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Unknown readings stay null. RSS, native heap and system RAM are distinct;
/// they must never be added together as an estimate of app memory.
class ResourceSample {
  ResourceSample(Map<Object?, Object?> data, {DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now(),
        availableBytes = _number(data['availableBytes']),
        totalBytes = _number(data['totalBytes']),
        thresholdBytes = _number(data['thresholdBytes']),
        rssBytes = _number(data['rssBytes']),
        nativeHeapBytes = _number(data['nativeHeapBytes']),
        lowMemory = data['lowMemory'] == true,
        trimLevel = _number(data['trimLevel']) ?? 0;

  final DateTime timestamp;
  final int? availableBytes,
      totalBytes,
      thresholdBytes,
      rssBytes,
      nativeHeapBytes;
  final bool lowMemory;
  final int trimLevel;
  static int? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toInt() : null;

  // UI_HIDDEN=20 and background levels are lifecycle signals, not evidence
  // of foreground RAM pressure. Android 14+ may omit trim notifications.
  bool get critical =>
      lowMemory ||
      trimLevel == 15 ||
      (availableBytes != null &&
          thresholdBytes != null &&
          availableBytes! <= thresholdBytes!);
  bool get pressured =>
      critical ||
      trimLevel == 5 ||
      trimLevel == 10 ||
      (availableBytes != null &&
          thresholdBytes != null &&
          availableBytes! < thresholdBytes! + 512 * 1024 * 1024);
  String get pressure => critical
      ? 'critical'
      : pressured
          ? 'high'
          : availableBytes != null && thresholdBytes != null
              ? 'normal'
              : 'unknown';
}

int minResourceGenerationLimit(int context) => (context ~/ 2).clamp(1, 2048);

class ResourceProfile {
  const ResourceProfile(this.context, this.batch, this.microBatch, this.reason);
  final int context, batch, microBatch;
  final String reason;
  static ResourceProfile select(ResourceSample? sample, {required bool phi}) {
    if (sample?.pressured == true) {
      return const ResourceProfile(2048, 128, 32, 'pressure');
    }
    if (phi) return const ResourceProfile(2048, 128, 64, 'phi_conservative');
    // Keep a smaller KV/compute allocation on phones with at most 8 GiB.
    // Free RAM alone can look healthy before weights become resident.
    final total = sample?.totalBytes;
    if (total != null && total > 0 && total <= 8 * 1024 * 1024 * 1024) {
      // 3B-class non-Phi models can cross Android's critical-memory boundary
      // during later Workshop roles even when the pre-load sample looks
      // healthy. Start pressure-compatible so Engineer/Reviewer do not need a
      // mid-generation cancellation merely to shrink batch allocation.
      return const ResourceProfile(
        2048,
        128,
        32,
        'device_memory_conservative',
      );
    }
    return const ResourceProfile(4096, 512, 128, 'baseline');
  }
}

/// Sampling is owned by active inference and visible panels, not by a route.
/// At most one platform request is in flight. The ring and persisted event
/// stream are bounded; no network operation is performed by this service.
class ResourceMonitor extends ChangeNotifier {
  ResourceMonitor({
    Future<Map<Object?, Object?>?> Function()? sampler,
    void Function(String)? logger,
  })  : _sampler = sampler ?? _platformSample,
        _logger = logger ?? RuntimeEventLog.instance.emit;
  static final instance = ResourceMonitor();
  static const _channel = MethodChannel('com.aiorchestrator/resources');
  final Future<Map<Object?, Object?>?> Function() _sampler;
  final void Function(String) _logger;
  final Queue<ResourceSample> _history = Queue<ResourceSample>();
  List<ResourceSample> get history => List.unmodifiable(_history);
  ResourceSample? latest;
  Map<String, int> native = const {};
  Map<String, int> Function()? readNative;
  String phase = 'idle';
  Timer? _timer;
  Future<ResourceSample?>? _pending;
  Future<Map<Object?, Object?>?>? _sensorPending;
  int _owners = 0;
  bool _disposed = false;
  final Set<VoidCallback> _criticalListeners = {};
  void addCriticalListener(VoidCallback listener) =>
      _criticalListeners.add(listener);
  void removeCriticalListener(VoidCallback listener) =>
      _criticalListeners.remove(listener);

  static Future<Map<Object?, Object?>?> _platformSample() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return _channel.invokeMapMethod<Object?, Object?>('sample');
  }

  void retain() {
    if (_disposed) return;
    _owners++;
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(sample());
    });
    unawaited(sample());
  }

  void release() {
    if (_owners > 0) _owners--;
    if (_owners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<ResourceSample?> sample() => _disposed
      ? Future.value(null)
      : _pending ??= _takeSample().whenComplete(() {
          _pending = null;
        });
  Future<ResourceSample?> _takeSample() async {
    ResourceSample? reading;
    try {
      final pending = _sensorPending ??=
          Future<Map<Object?, Object?>?>.sync(_sampler).whenComplete(() {
        _sensorPending = null;
      });
      final data = await pending.timeout(const Duration(seconds: 1));
      if (data != null) reading = ResourceSample(data);
    } on Object {
      /* Missing plugin/unsupported platform is not zero RAM. */
    }
    if (_disposed) return null;
    latest = reading;
    try {
      native = Map<String, int>.of(readNative?.call() ?? const {})
        ..removeWhere((key, value) => value < 0);
    } on Object {
      native = const {};
    }
    if (reading != null) {
      if (_history.length >= 60) _history.removeFirst();
      _history.addLast(reading);
      try {
        _logger(
          '[RESOURCE_SAMPLE] available_bytes=${reading.availableBytes ?? -1} '
          'rss_bytes=${reading.rssBytes ?? -1} native_heap_bytes=${reading.nativeHeapBytes ?? -1} '
          'critical=${reading.critical} phase=$phase '
          'gpu_layers=${native['gpu_layers'] ?? -1} '
          'decode_calls=${native['decode_calls'] ?? -1} '
          'total_bytes=${reading.totalBytes ?? -1} threshold_bytes=${reading.thresholdBytes ?? -1} '
          'pressure=${reading.pressure} low_memory=${reading.lowMemory} trim_level=${reading.trimLevel} '
          'n_ctx=${native['context'] ?? -1} n_batch=${native['batch'] ?? -1} '
          'n_ubatch=${native['micro_batch'] ?? -1}',
        );
      } on Object {
        // Diagnostics must never disable the memory guard or sampling.
      }
      if (reading.critical) {
        for (final listener in List<VoidCallback>.of(_criticalListeners)) {
          try {
            listener();
          } on Object {
            // Notify every owner even if another cancellation handler fails.
          }
        }
      }
    }
    notifyListeners();
    return reading;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _criticalListeners.clear();
    readNative = null;
    super.dispose();
  }
}
