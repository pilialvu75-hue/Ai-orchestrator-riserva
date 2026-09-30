import 'dart:async';
import 'dart:io';

import 'benchmark_hardware_profile_common.dart';

Future<String> collectBenchmarkHardwareProfile(String platformName) async {
  final normalized = platformName.toLowerCase();
  final snapshot = switch (normalized) {
    'windows' => await _windowsSnapshot(),
    'linux' => await _linuxSnapshot(),
    'macos' => await _macosSnapshot(),
    _ => BenchmarkHardwareSnapshot(
        platform: normalized,
        deviceClass: 'device',
        architecture: _environmentArchitecture(),
        osVersion: Platform.operatingSystemVersion,
      ),
  };
  return buildBenchmarkHardwareProfile(snapshot);
}

Future<BenchmarkHardwareSnapshot> _windowsSnapshot() async {
  final computerSystem = await _run(
    'wmic',
    const <String>[
      'computersystem',
      'get',
      'Manufacturer,Model,TotalPhysicalMemory',
      '/value',
    ],
  );
  final cpuOutput = await _run(
    'wmic',
    const <String>['cpu', 'get', 'Name', '/value'],
  );
  final gpuOutput = await _run(
    'wmic',
    const <String>[
      'path',
      'win32_VideoController',
      'get',
      'Name',
      '/value',
    ],
  );

  var manufacturer = _firstValue(computerSystem, 'Manufacturer');
  var model = _firstValue(computerSystem, 'Model');
  var memory = _intValue(computerSystem, 'TotalPhysicalMemory');
  var cpu = _firstValue(cpuOutput, 'Name');
  var gpu = _allValues(gpuOutput, 'Name').join(', ');

  // WMIC is present on Windows 7/8.1 and many Windows 10 installations.
  // Newer Windows may remove it, so use PowerShell/CIM only as a fallback.
  manufacturer ??= await _runPowerShell(
    '(Get-CimInstance Win32_ComputerSystem).Manufacturer',
  );
  model ??= await _runPowerShell(
    '(Get-CimInstance Win32_ComputerSystem).Model',
  );
  memory ??= int.tryParse(
    (await _runPowerShell(
          '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
        )) ??
        '',
  );
  cpu ??= await _runPowerShell(
    '(Get-CimInstance Win32_Processor | Select-Object -First 1).Name',
  );
  if (gpu.trim().isEmpty) {
    gpu = (await _runPowerShell(
          '(Get-CimInstance Win32_VideoController | '
          'ForEach-Object { $_.Name }) -join ", "',
        )) ??
        '';
  }

  return BenchmarkHardwareSnapshot(
    platform: 'windows',
    deviceClass: 'desktop',
    manufacturer: manufacturer,
    model: model,
    cpu: cpu ?? Platform.environment['PROCESSOR_IDENTIFIER'],
    gpu: gpu.trim().isEmpty ? null : gpu.trim(),
    architecture: _environmentArchitecture(),
    totalMemoryBytes: memory,
    osVersion: Platform.operatingSystemVersion,
  );
}

Future<BenchmarkHardwareSnapshot> _linuxSnapshot() async {
  final boardModel = await _readFirstExisting(
    const <String>[
      '/sys/firmware/devicetree/base/model',
      '/proc/device-tree/model',
    ],
  );
  final productName = await _readFirstExisting(
    const <String>['/sys/devices/virtual/dmi/id/product_name'],
  );
  var manufacturer = await _readFirstExisting(
    const <String>['/sys/devices/virtual/dmi/id/sys_vendor'],
  );

  final cpuInfo = await _readText('/proc/cpuinfo');
  final cpu = _firstCpuIdentity(cpuInfo);
  final memInfo = await _readText('/proc/meminfo');
  final memory = _linuxMemoryBytes(memInfo);
  final architecture = (await _run('uname', const <String>['-m'])) ??
      _environmentArchitecture();

  final lspci = await _run('lspci', const <String>['-mm']);
  final gpu = _linuxGpuFromLspci(lspci);
  final deviceClass = classifyLinuxBenchmarkDevice(
    boardModel: boardModel,
    productName: productName,
  );
  if (deviceClass == 'raspberry_pi' &&
      (manufacturer == null || manufacturer.trim().isEmpty)) {
    manufacturer = 'Raspberry Pi';
  }

  return BenchmarkHardwareSnapshot(
    platform: 'linux',
    deviceClass: deviceClass,
    manufacturer: manufacturer,
    model: boardModel ?? productName,
    cpu: cpu,
    gpu: gpu,
    architecture: architecture,
    totalMemoryBytes: memory,
    osVersion: Platform.operatingSystemVersion,
  );
}

Future<BenchmarkHardwareSnapshot> _macosSnapshot() async {
  final model = await _run('sysctl', const <String>['-n', 'hw.model']);
  final cpu = await _run(
        'sysctl',
        const <String>['-n', 'machdep.cpu.brand_string'],
      ) ??
      await _run('sysctl', const <String>['-n', 'hw.machine']);
  final memory = int.tryParse(
    (await _run('sysctl', const <String>['-n', 'hw.memsize'])) ?? '',
  );
  final architecture = await _run('uname', const <String>['-m']);
  final displays = await _run(
    'system_profiler',
    const <String>['SPDisplaysDataType'],
  );

  return BenchmarkHardwareSnapshot(
    platform: 'macos',
    deviceClass: 'desktop',
    manufacturer: 'Apple',
    model: model,
    cpu: cpu,
    gpu: _macGpu(displays),
    architecture: architecture,
    totalMemoryBytes: memory,
    osVersion: Platform.operatingSystemVersion,
  );
}

Future<String?> _run(String executable, List<String> arguments) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: false,
    ).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) return null;
    final text = result.stdout.toString().trim();
    return text.isEmpty ? null : text;
  } on Object {
    return null;
  }
}

Future<String?> _runPowerShell(String command) async {
  final output = await _run(
    'powershell.exe',
    <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ],
  );
  return output?.trim();
}

Future<String?> _readText(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    final cleaned = text.replaceAll('\u0000', '').trim();
    return cleaned.isEmpty ? null : cleaned;
  } on Object {
    return null;
  }
}

Future<String?> _readFirstExisting(List<String> paths) async {
  for (final path in paths) {
    final value = await _readText(path);
    if (value != null) return value;
  }
  return null;
}

String? _firstValue(String? text, String key) {
  final values = _allValues(text, key);
  return values.isEmpty ? null : values.first;
}

int? _intValue(String? text, String key) =>
    int.tryParse(_firstValue(text, key) ?? '');

List<String> _allValues(String? text, String key) {
  if (text == null || text.isEmpty) return const <String>[];
  final prefix = '$key=';
  return text
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.startsWith(prefix))
      .map((line) => line.substring(prefix.length).trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

String? _firstCpuIdentity(String? cpuInfo) {
  if (cpuInfo == null) return null;
  for (final key in const <String>[
    'model name',
    'Hardware',
    'Processor',
  ]) {
    final expression = RegExp(
      '^' + RegExp.escape(key) + r'\s*:\s*(.+)$',
      caseSensitive: false,
      multiLine: true,
    );
    final match = expression.firstMatch(cpuInfo);
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

int? _linuxMemoryBytes(String? memInfo) {
  if (memInfo == null) return null;
  final match = RegExp(
    r'^MemTotal:\s+(\d+)\s+kB$',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(memInfo);
  final kib = int.tryParse(match?.group(1) ?? '');
  return kib == null ? null : kib * 1024;
}

String? _linuxGpuFromLspci(String? lspci) {
  if (lspci == null) return null;
  final matches = lspci
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) {
        final lower = line.toLowerCase();
        return lower.contains('vga compatible controller') ||
            lower.contains('3d controller') ||
            lower.contains('display controller');
      })
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  return matches.isEmpty ? null : matches.join(', ');
}

String? _macGpu(String? profilerOutput) {
  if (profilerOutput == null) return null;
  final matches = RegExp(
    r'Chipset Model:\s*(.+)$',
    caseSensitive: false,
    multiLine: true,
  )
      .allMatches(profilerOutput)
      .map((match) => match.group(1)?.trim())
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  return matches.isEmpty ? null : matches.join(', ');
}

String? _environmentArchitecture() {
  for (final key in const <String>[
    'PROCESSOR_ARCHITECTURE',
    'HOSTTYPE',
    'MACHTYPE',
  ]) {
    final value = Platform.environment[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
