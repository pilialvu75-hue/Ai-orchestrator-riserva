import 'dart:convert';

/// Converts the native Windows startup trace into a closed, privacy-safe
/// diagnostic record.
///
/// Only known stage numbers, exception codes and module basenames are exported.
/// Absolute paths, stack addresses and arbitrary native text never leave the
/// device.
String? windowsNativeTracePublicProjection(
  String raw, {
  required String source,
  required DateTime capturedAt,
}) {
  if (source != 'current' && source != 'previous') return null;

  String? lastStage;
  String? exceptionCode;
  String? faultModule;
  var fatal = false;
  var cleanShutdown = false;
  var recognized = false;
  final stackModules = <String>[];

  for (final rawLine in const LineSplitter().convert(raw)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final stage = RegExp(r'^(\d{2}[a-z]?)\s').firstMatch(line);
    if (stage != null) {
      lastStage = stage[1];
      recognized = true;
      if (lastStage == '17') cleanShutdown = true;
      continue;
    }

    if (line.startsWith('FATAL ')) {
      fatal = true;
      recognized = true;
      continue;
    }

    final code = RegExp(
      r'^fatal_exception_code=(0x[0-9A-Fa-f]{8})$',
    ).firstMatch(line);
    if (code != null) {
      exceptionCode = code[1]!.toUpperCase();
      fatal = true;
      recognized = true;
      continue;
    }

    final module = _safeModuleBasename(line, 'fatal_module=');
    if (module != null) {
      faultModule = module;
      recognized = true;
      continue;
    }

    final stackModule = _safeModuleBasename(line, 'fatal_stack_module=');
    if (stackModule != null) {
      recognized = true;
      if (stackModules.length < 8 && !stackModules.contains(stackModule)) {
        stackModules.add(stackModule);
      }
    }
  }

  if (!recognized) return null;

  return jsonEncode(<String, Object>{
    'time': capturedAt.toUtc().toIso8601String(),
    'event': 'WINDOWS_NATIVE_TRACE',
    'source': source,
    if (lastStage != null) 'last_stage': lastStage,
    'fatal': fatal,
    'clean_shutdown': cleanShutdown,
    if (exceptionCode != null) 'exception_code': exceptionCode,
    if (faultModule != null) 'fault_module': faultModule,
    if (stackModules.isNotEmpty) 'stack_modules': stackModules,
  });
}

String? _safeModuleBasename(String line, String prefix) {
  if (!line.startsWith(prefix)) return null;
  final rawPath = line.substring(prefix.length).trim();
  if (rawPath.isEmpty || rawPath.startsWith('<')) return null;

  final normalized = rawPath.replaceAll('\\', '/');
  final basename = normalized.split('/').last;
  if (!RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(basename)) {
    return null;
  }
  return basename;
}
