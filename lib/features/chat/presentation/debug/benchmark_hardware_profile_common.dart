class BenchmarkHardwareSnapshot {
  const BenchmarkHardwareSnapshot({
    required this.platform,
    required this.deviceClass,
    this.manufacturer,
    this.model,
    this.cpu,
    this.gpu,
    this.architecture,
    this.totalMemoryBytes,
    this.osVersion,
  });

  final String platform;
  final String deviceClass;
  final String? manufacturer;
  final String? model;
  final String? cpu;
  final String? gpu;
  final String? architecture;
  final int? totalMemoryBytes;
  final String? osVersion;
}

String buildBenchmarkHardwareProfile(BenchmarkHardwareSnapshot snapshot) {
  String value(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return 'unknown';
    return text
        .replaceAll(RegExp(r'[\r\n\u0000|]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  return <String>[
    'hardware-v2',
    'platform:${value(snapshot.platform)}',
    'class:${value(snapshot.deviceClass)}',
    'manufacturer:${value(snapshot.manufacturer)}',
    'model:${value(snapshot.model)}',
    'cpu:${value(snapshot.cpu)}',
    'gpu:${value(snapshot.gpu)}',
    'arch:${value(snapshot.architecture)}',
    'ram:${snapshot.totalMemoryBytes ?? -1}',
    'os:${value(snapshot.osVersion)}',
  ].join('|');
}

String classifyLinuxBenchmarkDevice({
  String? boardModel,
  String? productName,
}) {
  final identity = '${boardModel ?? ''} ${productName ?? ''}'.toLowerCase();
  if (identity.contains('raspberry pi')) return 'raspberry_pi';
  return 'desktop';
}
