import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Adapter identity is the WDDM counter LUID and physical index, not a
/// vendor index. Dedicated and shared allocations must remain distinct.
class WindowsWddmMemorySample {
  const WindowsWddmMemorySample(this.adapterId, this.dedicatedBytes,
      this.sharedBytes, {this.busiestEnginePercent});

  final String adapterId;
  final int? dedicatedBytes, sharedBytes, busiestEnginePercent;

  static List<WindowsWddmMemorySample> parse(String output) {
    final result = <WindowsWddmMemorySample>[];
    final seen = <String>{};
    final engineRows = <String>{};
    final engineTotals = <String, Map<String, int>>{};
    final invalidAdapters = <String>{};
    final enginePattern = RegExp(
      r'^pid_\d+_(luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+)_(eng_\d+)_engtype_[a-z0-9_]+
    final pattern = RegExp(r'^luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+$',
        caseSensitive: false);
    int? bytes(String field) {
      final value = int.tryParse(field.trim());
      return value != null && value >= 0 ? value : null;
    }
    for (final line in const LineSplitter().convert(output)) {
      final fields = line.split('|');
      if (fields.length != 3) continue;
      if (fields[0] == 'E') {
        final instance = fields[1].trim().toLowerCase();
        final match = enginePattern.firstMatch(instance);
        if (match == null) continue;
        final adapter = match.group(1)!;
        final engine = match.group(2)!;
        final value = bytes(fields[2]);
        if (value == null || value > 100 || !engineRows.add(instance)) {
          invalidAdapters.add(adapter);
          continue;
        }
        final totals = engineTotals.putIfAbsent(adapter, () => {});
        totals[engine] = (totals[engine] ?? 0) + value;
        if (totals[engine]! > 100) invalidAdapters.add(adapter);
        continue;
      }
      final id = fields[0].trim().toLowerCase();
      if (!pattern.hasMatch(id) || !seen.add(id)) continue;
      final dedicated = bytes(fields[1]);
      final shared = bytes(fields[2]);
      if (dedicated == null && shared == null) continue;
      result.add(WindowsWddmMemorySample(id, dedicated, shared));
    }
    // Each physical engine is shared by processes. Sum per engine, then
    // take the busiest engine, never the sum of different engines.
    int? utilization(String adapter) {
      final totals = engineTotals[adapter];
      if (invalidAdapters.contains(adapter) || totals == null || totals.isEmpty) {
        return null;
      }
      return totals.values.reduce((a, b) => a > b ? a : b);
    }
    final combined = [
      for (final memory in result)
        WindowsWddmMemorySample(memory.adapterId, memory.dedicatedBytes,
            memory.sharedBytes, busiestEnginePercent: utilization(memory.adapterId)),
      for (final adapter in engineTotals.keys)
        if (!result.any((memory) => memory.adapterId == adapter) &&
            utilization(adapter) != null)
          WindowsWddmMemorySample(adapter, null, null,
              busiestEnginePercent: utilization(adapter)),
    ];
    return List.unmodifiable(combined);
  }
}

/// Uses invariant CIM class/property names, not localized PerfMon names.
/// Unsupported OS/driver, timeout or missing counters all return unknown.
abstract final class WindowsWddmMemory {
  static Future<List<WindowsWddmMemorySample>> sample() async {
    if (!Platform.isWindows) return const [];
    final root = Platform.environment['SystemRoot'];
    if (root == null || !p.windows.isAbsolute(root)) return const [];
    final executable = p.windows.join(root, 'System32', 'WindowsPowerShell',
        'v1.0', 'powershell.exe');
    if (!await File(executable).exists()) return const [];

    // Fixed local read-only query; no user-supplied command or shell expansion.
    const script = r'''
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Version.Major -lt 10) { exit 0 }
try {
  Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory |
    ForEach-Object {
      [Console]::WriteLine(('{0}|{1}|{2}' -f $_.Name, $_.DedicatedUsage, $_.SharedUsage))
    }
} catch {}
try {
  Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine |
    ForEach-Object {
      [Console]::WriteLine(('E|{0}|{1}' -f $_.Name, $_.UtilizationPercentage))
    }
} catch {}
''';
    Process? process;
    try {
      process = await Process.start(executable, const [
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script,
      ]);
      final output = await Future.wait<Object>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<void>().then((_) => true),
        process.exitCode,
      ]).timeout(const Duration(seconds: 3));
      if (output[2] != 0) return const [];
      return WindowsWddmMemorySample.parse(output[0] as String);
    } on Object {
      process?.kill();
      return const [];
    }
  }
}
,
      caseSensitive: false,
    );
    final pattern = RegExp(r'^luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+$',
        caseSensitive: false);
    int? bytes(String field) {
      final value = int.tryParse(field.trim());
      return value != null && value >= 0 ? value : null;
    }
    for (final line in const LineSplitter().convert(output)) {
      final fields = line.split('|');
      if (fields.length != 3) continue;
      final id = fields[0].trim().toLowerCase();
      if (!pattern.hasMatch(id) || !seen.add(id)) continue;
      final dedicated = bytes(fields[1]);
      final shared = bytes(fields[2]);
      if (dedicated == null && shared == null) continue;
      result.add(WindowsWddmMemorySample(id, dedicated, shared));
    }
    return List.unmodifiable(result);
  }
}

/// Uses invariant CIM class/property names, not localized PerfMon names.
/// Unsupported OS/driver, timeout or missing counters all return unknown.
abstract final class WindowsWddmMemory {
  static Future<List<WindowsWddmMemorySample>> sample() async {
    if (!Platform.isWindows) return const [];
    final root = Platform.environment['SystemRoot'];
    if (root == null || !p.windows.isAbsolute(root)) return const [];
    final executable = p.windows.join(root, 'System32', 'WindowsPowerShell',
        'v1.0', 'powershell.exe');
    if (!await File(executable).exists()) return const [];

    // Fixed local read-only query; no user-supplied command or shell expansion.
    const script = r'''
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Version.Major -lt 10) { exit 0 }
Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory |
  ForEach-Object {
    [Console]::WriteLine(('{0}|{1}|{2}' -f $_.Name, $_.DedicatedUsage, $_.SharedUsage))
  }
''';
    Process? process;
    try {
      process = await Process.start(executable, const [
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script,
      ]);
      final output = await Future.wait<Object>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<void>().then((_) => true),
        process.exitCode,
      ]).timeout(const Duration(seconds: 3));
      if (output[2] != 0) return const [];
      return WindowsWddmMemorySample.parse(output[0] as String);
    } on Object {
      process?.kill();
      return const [];
    }
  }
}
