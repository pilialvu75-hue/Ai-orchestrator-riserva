import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Disk-backed persistence for [RuntimeEventLog] entries.
///
/// [RuntimeEventLog] on its own only keeps entries in memory (a capped
/// in-process list). If the app process is killed by a native crash —
/// e.g. a SIGSEGV inside `llama_bridge.cpp` while loading a model or
/// initialising GPU offload — the in-memory buffer dies with the
/// process and nothing survives to explain what happened. Dart-level
/// exception handlers (`FlutterError.onError`, `PlatformDispatcher
/// .onError`, isolate error listeners) never run in that case, because
/// the process itself is terminated by the OS, not by a Dart exception.
///
/// This sink appends every log line to a plain text file on disk,
/// synchronously and with an immediate flush, so that whatever was
/// logged right up to the moment of a native crash is already saved
/// to disk before the crash can happen.
///
/// This is a diagnostic aid only: every method fails safe. If disk
/// persistence cannot be initialised or a write fails, the app must
/// keep running exactly as if this class did not exist.
class RuntimeCrashLogSink {
  RuntimeCrashLogSink._();

  /// Singleton instance shared across the app.
  static final RuntimeCrashLogSink instance = RuntimeCrashLogSink._();

  static const String _fileName = 'runtime_crash_log.txt';

  /// Safety cap: if the log file grows past this size, it is trimmed
  /// back to its most recent half. Prevents a runaway logging loop
  /// (e.g. a crash/retry cycle) from filling the device's storage.
  static const int _maxFileBytes = 5 * 1024 * 1024;

  File? _file;
  bool _ready = false;
  bool _initFailed = false;

  /// Prepares the on-disk log file. Must be awaited exactly once, as
  /// early as possible in `main()` — before installing exception
  /// handlers and before any runtime/inference activity starts —
  /// so that no early log line is lost.
  Future<void> init() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$_fileName');
      if (!file.existsSync()) {
        file.createSync(recursive: true);
      }
      _file = file;
      _ready = true;
    } catch (_) {
      // Persistence is a diagnostic aid, never a hard dependency: if
      // initialisation fails, the app must continue exactly as before.
      _initFailed = true;
      _ready = false;
    }
  }

  /// Appends [line] to the log file synchronously, with an immediate
  /// flush to disk. Does nothing if persistence is not ready.
  void append(String line) {
    final file = _file;
    if (!_ready || file == null) return;
    try {
      file.writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
      _enforceMaxSizeIfNeeded(file);
    } catch (_) {
      // Never let a logging failure crash the very app it is meant
      // to help diagnose.
    }
  }

  void _enforceMaxSizeIfNeeded(File file) {
    try {
      final length = file.lengthSync();
      if (length <= _maxFileBytes) return;
      final content = file.readAsStringSync();
      final keepFrom = (content.length / 2).floor();
      final trimmed = content.substring(keepFrom);
      file.writeAsStringSync(
        '[LOG_TRUNCATED_TO_LIMIT_BYTES=$_maxFileBytes]\n$trimmed',
        mode: FileMode.write,
        flush: true,
      );
    } catch (_) {
      // Best-effort housekeeping only.
    }
  }

  /// Reads the full persisted log as text.
  ///
  /// Returns a human-readable placeholder instead of throwing when
  /// persistence never initialised or the file does not exist yet —
  /// this is shown directly in a debug UI, not just logged.
  Future<String> readAsText() async {
    final file = _file;
    if (!_ready || file == null) {
      if (_initFailed) {
        return '(log su disco non disponibile: inizializzazione fallita)';
      }
      return '(log su disco non ancora inizializzato)';
    }
    try {
      if (!await file.exists()) {
        return '(nessun log salvato finora)';
      }
      final content = await file.readAsString();
      return content.trim().isEmpty
          ? '(file di log presente ma vuoto)'
          : content;
    } catch (error) {
      return '(errore durante la lettura del log: $error)';
    }
  }

  /// Deletes the content of the persisted log file, if present.
  Future<void> clear() async {
    final file = _file;
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.writeAsString('', flush: true);
      }
    } catch (_) {
      // Best-effort: clearing the diagnostic file must never crash the app.
    }
  }

  /// Absolute path of the persisted log file, for display purposes only.
  String? get filePath => _file?.path;
}
