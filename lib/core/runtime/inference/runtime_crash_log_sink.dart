import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Disk-backed persistence for [RuntimeEventLog] entries.
///
/// [RuntimeEventLog] on its own only keeps entries in memory.
/// If the app process is killed by a native crash — for example
/// a SIGSEGV inside a native runtime — the in-memory buffer dies
/// with the process.
///
/// Critical and unknown events are flushed immediately. Explicitly classified
/// nonterminal progress events are batched, with a bounded timer and size.
/// A sudden process crash may lose the most recent buffered progress only.
///
/// This is diagnostic infrastructure only: every method deliberately
/// fails safe. A logging problem must never crash the application.
class RuntimeCrashLogSink {
  RuntimeCrashLogSink._();

  /// Singleton instance shared across the app.
  static final RuntimeCrashLogSink instance =
      RuntimeCrashLogSink._();

  static const String _fileName =
      'runtime_crash_log.txt';

  /// Safety cap for the persistent forensic log.
  ///
  /// 1 MB is intentionally enough for many hundreds/thousands of
  /// diagnostic events while remaining practical to inspect on a
  /// mobile device.
  ///
  /// When this threshold is exceeded, the oldest half of the log is
  /// discarded and the most recent half is kept.
  static const int _maxFileBytes =
      1 * 1024 * 1024;

  static const _progressFlushInterval = Duration(milliseconds: 250);
  static const _maxPendingLines = 64;
  // UTF-16 code units times three upper-bounds UTF-8 bytes, including
  // supplementary characters. Bound pending memory independently of count.
  static const _maxPendingBytes = 64 * 1024;
  final List<String> _pending = [];
  int _pendingBytes = 0;
  Timer? _flushTimer;

  File? _file;

  bool _ready = false;

  bool _initFailed = false;

  /// Prepares the on-disk log file.
  ///
  /// This should be awaited once, as early as possible in main(),
  /// before runtime/inference/voice activity starts.
  Future<void> init() async {
    _flushPending();
    _ready = false;
    try {
      final directory =
          await getApplicationDocumentsDirectory();

      final file = File(
        '${directory.path}/$_fileName',
      );

      if (!file.existsSync()) {
        file.createSync(
          recursive: true,
        );
      }

      _file = file;

      _ready = true;

      _initFailed = false;

      // An installation upgraded from an older build may already
      // contain the previous multi-megabyte diagnostic file.
      // Apply the new limit immediately instead of waiting for the
      // next append.
      _enforceMaxSizeIfNeeded(
        file,
      );
    } catch (_) {
      _initFailed = true;

      _ready = false;
    }
  }

  /// Only positively identified nonterminal progress may be deferred.
  /// Everything else, including native boundaries and errors, is durable
  /// on the same best-effort basis as before, in original event order.
  void append(String line, {bool routineProgress = false}) {
    if (!_ready || _file == null) return;

    _pending.add(line);
    _pendingBytes += (line.length + 1) * 3;

    if (!routineProgress ||
        _pending.length >= _maxPendingLines ||
        _pendingBytes >= _maxPendingBytes) {
      _flushPending();
      return;
    }
    _flushTimer ??= Timer(_progressFlushInterval, _flushPending);
  }

  void _discardPending() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _pendingBytes = 0;
  }

  void _flushPending() {
    final file = _file;
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final batch = '${_pending.join('\n')}\n';
    _discardPending();
    if (!_ready || file == null) return;
    try {
      file.writeAsStringSync(batch, mode: FileMode.append, flush: true);
      _enforceMaxSizeIfNeeded(file);
    } catch (_) {
      // Preserve the existing best-effort persistence contract. Do not
      // retry a potentially partial append or let diagnostics crash the app.
    }
  }

  void _enforceMaxSizeIfNeeded(
    File file,
  ) {
    try {
      final length =
          file.lengthSync();

      if (length <=
          _maxFileBytes) {
        return;
      }

      final content =
          file.readAsStringSync();

      if (content.isEmpty) {
        return;
      }

      final approximateKeepFrom =
          content.length ~/ 2;

      // Prefer starting from a complete log line instead of cutting
      // through the middle of an event.
      final nextLineBreak =
          content.indexOf(
        '\n',
        approximateKeepFrom,
      );

      final keepFrom =
          nextLineBreak >= 0
              ? nextLineBreak + 1
              : approximateKeepFrom;

      final trimmed =
          content.substring(
        keepFrom,
      );

      file.writeAsStringSync(
        '[LOG_TRUNCATED_TO_LIMIT_BYTES='
        '$_maxFileBytes]\n'
        '$trimmed',
        mode:
            FileMode.write,
        flush: true,
      );
    } catch (_) {
      // Best-effort housekeeping only.
    }
  }

  /// Reads the full persisted log as text.
  ///
  /// Returns a human-readable placeholder rather than throwing when
  /// persistence is unavailable because this text is shown directly
  /// by Debug Lab.
  Future<String> readAsText() async {
    _flushPending();
    final file = _file;

    if (!_ready ||
        file == null) {
      if (_initFailed) {
        return '(log su disco non disponibile: '
            'inizializzazione fallita)';
      }

      return '(log su disco non ancora inizializzato)';
    }

    try {
      if (!await file.exists()) {
        return '(nessun log salvato finora)';
      }

      final content =
          await file.readAsString();

      return content.trim().isEmpty
          ? '(file di log presente ma vuoto)'
          : content;
    } catch (error) {
      return '(errore durante la lettura del log: '
          '$error)';
    }
  }

  /// Clears the persistent forensic log.
  ///
  /// The file itself is intentionally retained so persistence can
  /// immediately resume without having to recreate the sink.
  Future<void> clear() async {
    _discardPending();
    final file = _file;

    if (file == null) {
      return;
    }

    try {
      // Reset is rare and explicit. Keep it ordered with synchronous
      // boundary writes; no await may allow an event to race truncation.
      if (file.existsSync()) {
        file.writeAsStringSync('', mode: FileMode.write, flush: true);
      }
    } catch (_) {
      // Clearing diagnostics must never crash the app.
    }
  }

  /// Absolute path of the persisted log file.
  ///
  /// Intended only for diagnostics/display purposes.
  String? get filePath =>
      _file?.path;
}
