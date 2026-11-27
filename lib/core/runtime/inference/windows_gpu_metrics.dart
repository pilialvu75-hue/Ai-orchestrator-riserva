import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// Device-wide NVIDIA measurements, not per-process GPU attribution.
class WindowsGpuSample {
  const WindowsGpuSample(this.index, this.name, this.utilizationPercent,
      this.usedMiB, this.totalMiB);
  final int index;
  final String name;
  final int? utilizationPercent, usedMiB, totalMiB;

  static List<WindowsGpuSample> parse(String output) {
    final samples = <WindowsGpuSample>[];
    final seen = <int>{};
    int? nonnegative(String value) {
      final number = int.tryParse(value.trim());
      return number != null && number >= 0 ? number : null;
    }
    for (final line in const LineSplitter().convert(output)) {
      final fields = line.split(',').map((field) => field.trim()).toList();
      if (fields.length != 5) continue;
      final index = nonnegative(fields[0]);
      if (index == null || fields[1].isEmpty || !seen.add(index)) continue;
      final utilization = nonnegative(fields[2]);
      final used = nonnegative(fields[3]);
      final total = nonnegative(fields[4]);
      samples.add(WindowsGpuSample(
        index, fields[1],
        utilization != null && utilization <= 100 ? utilization : null,
        used != null && total != null && used > total ? null : used,
        total != null && total > 0 ? total : null,
      ));
    }
    return List.unmodifiable(samples);
  }
}

/// Polls only while the Windows metrics panel is visible. No inference gates.
class WindowsGpuMetrics extends ChangeNotifier {
  WindowsGpuMetrics({Future<List<WindowsGpuSample>> Function()? sampler,
      void Function(String)? logger})
      : _sampler = sampler ?? _sampleDriver,
        _logger = logger ?? RuntimeEventLog.instance.emit;

  static final instance = WindowsGpuMetrics();
  final Future<List<WindowsGpuSample>> Function() _sampler;
  final void Function(String) _logger;
  List<WindowsGpuSample> _latest = const [];
  List<WindowsGpuSample> get latest => _latest;
  Timer? _timer;
  bool _pending = false;
  bool _disposed = false;
  int _owners = 0;
  int _epoch = 0;

  void retain() {
    if (_disposed) return;
    if (++_owners != 1) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(sample());
    });
    unawaited(sample());
  }

  void release() {
    if (_owners == 0 || --_owners != 0) return;
    _timer?.cancel();
    _timer = null;
    _epoch++;
    _latest = const [];
  }

  Future<void> sample() async {
    if (_disposed || _owners == 0 || _pending) return;
    _pending = true;
    final epoch = _epoch;
    List<WindowsGpuSample> readings = const [];
    try {
      readings = await _sampler();
    } on Object {
      // Driver missing, unsupported or failed: remain unknown.
    } finally {
      _pending = false;
    }
    if (_disposed || _owners == 0 || epoch != _epoch) return;
    _latest = List.unmodifiable(readings);
    for (final gpu in readings) {
      try {
        _logger('[WINDOWS_GPU_RESOURCE] index=${gpu.index} '
            'device_util_pct=${gpu.utilizationPercent ?? -1} '
            'device_vram_used_mib=${gpu.usedMiB ?? -1} '
            'device_vram_total_mib=${gpu.totalMiB ?? -1}');
      } on Object {
        // Logging cannot affect inference or the display.
      }
    }
    notifyListeners();
  }

  static Future<List<WindowsGpuSample>> _sampleDriver() async {
    if (!Platform.isWindows) return const [];
    final env = Platform.environment;
    final roots = <String?>[env['SystemRoot'], env['ProgramW6432'], env['ProgramFiles']];
    final candidates = <String>{};
    for (var i = 0; i < roots.length; i++) {
      final root = roots[i];
      if (root == null || !p.windows.isAbsolute(root)) continue;
      candidates.add(i == 0
          ? p.windows.join(root, 'System32', 'nvidia-smi.exe')
          : p.windows.join(root, 'NVIDIA Corporation', 'NVSMI', 'nvidia-smi.exe'));
    }
    String? executable;
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        executable = candidate;
        break;
      }
    }
    if (executable == null) return const [];
    // Never use PATH or a shell; only the installed driver's known locations.
    final process = await Process.start(executable, const [
      '--query-gpu=index,name,utilization.gpu,memory.used,memory.total',
      '--format=csv,noheader,nounits',
    ]);
    try {
      final output = await Future.wait<Object>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<void>().then((_) => true),
        process.exitCode,
      ]).timeout(const Duration(seconds: 3));
      if (output[2] != 0) return const [];
      return WindowsGpuSample.parse(output[0] as String);
    } on Object {
      process.kill();
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _epoch++;
    _latest = const [];
    super.dispose();
  }
}
